{-# Language NamedFieldPuns #-}
{-# Language DataKinds #-}
{-# Language OverloadedStrings #-}
{-# Language TypeApplications #-}

module EVM.Symbolic where

import Prelude hiding  (Word)
import qualified Data.ByteString as BS
import Data.ByteString (ByteString)
import Control.Lens hiding (op, (:<), (|>), (.>))
import Data.Maybe                   (fromMaybe, fromJust)
import EVM.Types
import EVM.Concrete (Word (..), Whiff(..))
import qualified EVM.Concrete as Concrete
import Data.SBV hiding (runSMT, newArray_, addAxiom, Word)
import qualified Data.SBV.List as SL
import Data.SBV.List ((.++), (.!!))

-- | Symbolic words of 256 bits, possibly annotated with additional
--   "insightful" information
data SymWord = S Whiff (SWord 256)

-- | Convenience functions transporting between the concrete and symbolic realm
sw256 :: SWord 256 -> SymWord
sw256 = S Dull

litWord :: Word -> (SymWord)
litWord (C whiff a) = S whiff (literal $ toSizzle a)

w256lit :: W256 -> SymWord
w256lit = S Dull . literal . toSizzle

litAddr :: Addr -> SAddr
litAddr = SAddr . literal . toSizzle

litBytes :: ByteString -> [SWord 8]
litBytes bs = fmap (toSized . literal) (BS.unpack bs)

maybeLitWord :: SymWord -> Maybe Word
maybeLitWord (S whiff a) = fmap (C whiff . fromSizzle) (unliteral a)

maybeLitAddr :: SAddr -> Maybe Addr
maybeLitAddr (SAddr a) = fmap fromSizzle (unliteral a)

maybeLitBytes :: [SWord 8] -> Maybe ByteString
maybeLitBytes xs = fmap (\x -> BS.pack (fmap fromSized x)) (mapM unliteral xs)

-- | Note: these forms are crude and in general,
-- the continuation passing style `forceConcrete`
-- alternatives should be prefered for better error
-- handling when used during EVM execution

forceLit :: SymWord -> Word
forceLit (S whiff a) = case unliteral a of
  Just c -> C whiff (fromSizzle c)
  Nothing -> error "unexpected symbolic argument"

forceLitBytes :: [SWord 8] -> ByteString
forceLitBytes = BS.pack . fmap (fromSized . fromJust . unliteral)


-- | Arithmetic operations on SymWord

sdiv :: SymWord -> SymWord -> SymWord
sdiv (S _ x) (S _ y) = let sx, sy :: SInt 256
                           sx = sFromIntegral x
                           sy = sFromIntegral y
                       in sw256 $ sFromIntegral (sx `sQuot` sy)

smod :: SymWord -> SymWord -> SymWord
smod (S _ x) (S _ y) = let sx, sy :: SInt 256
                           sx = sFromIntegral x
                           sy = sFromIntegral y
                       in sw256 $ ite (y .== 0) 0 (sFromIntegral (sx `sRem` sy))

addmod :: SymWord -> SymWord -> SymWord -> SymWord
addmod (S _ x) (S _ y) (S _ z) = let to512 :: SWord 256 -> SWord 512
                                     to512 = sFromIntegral
                                 in sw256 $ sFromIntegral $ ((to512 x) + (to512 y)) `sMod` (to512 z)

mulmod :: SymWord -> SymWord -> SymWord -> SymWord
mulmod (S _ x) (S _ y) (S _ z) = let to512 :: SWord 256 -> SWord 512
                                     to512 = sFromIntegral
                                 in sw256 $ sFromIntegral $ ((to512 x) * (to512 y)) `sMod` (to512 z)

slt :: SymWord -> SymWord -> SymWord
slt (S _ x) (S _ y) =
  sw256 $ ite (sFromIntegral x .< (sFromIntegral y :: (SInt 256))) 1 0

sgt :: SymWord -> SymWord -> SymWord
sgt (S _ x) (S _ y) =
  sw256 $ ite (sFromIntegral x .> (sFromIntegral y :: (SInt 256))) 1 0

-- | Operations over static symbolic memory (list of symbolic bytes)
truncpad :: Int -> [SWord 8] -> [SWord 8]
truncpad n xs = if m > n then take n xs
                else mappend xs (replicate (n - m) 0)
  where m = length xs

-- returns undefined stuff when you try to take too much
takeStatic :: (SymVal a) => Int -> SList a -> [SBV a]
takeStatic n ls =
  let (x, xs) = SL.uncons ls
  in x:(takeStatic (n - 1) xs)

truncpad' :: Int -> SList (WordN 8) -> [SWord 8]
truncpad' n xs =
  ite
    (m .> (literal (num n)))
    (takeStatic n xs)
    (takeStatic n (xs .++ SL.implode (replicate n 0)))
  where m = SL.length xs

swordAt :: Int -> [SWord 8] -> SymWord
swordAt i bs = sw256 . fromBytes $ truncpad 32 $ drop i bs

swordAt' :: SInteger -> SList (WordN 8) -> SymWord
swordAt' i bs = sw256 . fromBytes $ truncpad' 32 $ SL.drop i bs

readByteOrZero' :: Int -> [SWord 8] -> SWord 8
readByteOrZero' i bs = fromMaybe 0 (bs ^? ix i)

sliceWithZero' :: Int -> Int -> [SWord 8] -> [SWord 8]
sliceWithZero' o s m = truncpad s $ drop o m

writeMemory' :: [SWord 8] -> Word -> Word -> Word -> [SWord 8] -> [SWord 8]
writeMemory' bs1 (C _ n) (C _ src) (C _ dst) bs0 =
  let
    (a, b) = splitAt (num dst) bs0
    a'     = replicate (num dst - length a) 0
    c      = if src > num (length bs1)
             then replicate (num n) 0
             else sliceWithZero' (num src) (num n) bs1
    b'     = drop (num (n)) b
  in
    a <> a' <> c <> b'

readMemoryWord' :: Word -> [SWord 8] -> SymWord
readMemoryWord' (C _ i) m = sw256 $ fromBytes $ truncpad 32 (drop (num i) m)

readMemoryWord32' :: Word -> [SWord 8] -> SWord 32
readMemoryWord32' (C _ i) m = fromBytes $ truncpad 4 (drop (num i) m)

setMemoryWord' :: Word -> SymWord -> [SWord 8] -> [SWord 8]
setMemoryWord' (C _ i) (S _ x) =
  writeMemory' (toBytes x) 32 0 (num i)

setMemoryByte' :: Word -> SWord 8 -> [SWord 8] -> [SWord 8]
setMemoryByte' (C _ i) x =
  writeMemory' [x] 1 0 (num i)

readSWord' :: Word -> [SWord 8] -> SymWord
readSWord' (C _ i) x =
  if i > num (length x)
  then sw256 $ 0
  else swordAt (num i) x

-- | Operations over dynamic symbolic memory (smt list of bytes)
swordAt'' :: SWord 32 -> SList (WordN 8) -> SymWord
swordAt'' i bs = sw256 . fromBytes $ truncpad' 32 $ SL.drop (sFromIntegral i) bs

readByteOrZero'' :: SWord 32 -> SList (WordN 8) -> SWord 8
readByteOrZero'' i bs =
  ite (SL.length bs .> (sFromIntegral i + 1))
  (bs .!! (sFromIntegral i))
  (literal 0)

-- Warning: if (length bs0) < dst or (length bs1) < src + n we can get `havoc` garbage in the resulting
-- list. It should really be 0. If we could write the following function, we could pad appropriately:
-- replicate :: (SymVal a) => SInteger -> SBV a -> SList a
-- but I can't really write this...
-- 
-- TODO: make sure we enforce this condition before calling this
dynWriteMemory :: SList (WordN 8) -> SymWord -> SymWord -> SymWord -> SList (WordN 8) -> SList (WordN 8)
dynWriteMemory bs1 (S _ n) (S _ src) (S _ dst) bs0 =
  let
    n'      = sFromIntegral n
    src'    = sFromIntegral src
    dst'    = sFromIntegral dst

    a       = SL.take dst' bs0
    b       = SL.subList bs1 src' n'
    c       = ite (dst' + n' .> SL.length bs0)
              (SL.nil)
              (SL.drop (dst' + n') bs0)
  in
    a .++ b .++ c

dynWriteMemoryPadding :: SList (WordN 8) -> SList (WordN 8) -> SymWord -> SymWord -> SymWord -> SList (WordN 8) -> SList (WordN 8)
dynWriteMemoryPadding zeroList bs1 (S _ n) (S _ src) (S _ dst) bs0 =
  let
    bs0'    = bs0 .++ zeroList
    bs1'    = bs1 .++ zeroList
    n'      = sFromIntegral n
    src'    = sFromIntegral src
    dst'    = sFromIntegral dst

    a       = SL.take dst' bs0'
    b       = SL.subList bs1' src' n'
    c       = SL.drop (dst' + n') bs0'
  in
    a .++ b .++ c



-- TODO: ensure we actually pad with zeros
sliceWithZero'' :: SymWord -> SymWord -> SList (WordN 8) -> SList (WordN 8)
sliceWithZero'' (S _ o) (S _ s) m = SL.subList m (sFromIntegral s) (sFromIntegral o)



-- readMemoryWord' :: Word -> [SWord 8] -> SymWord
-- readMemoryWord' (C _ i) m = sw256 $ fromBytes $ truncpad 32 (drop (num i) m)

-- readMemoryWord32' :: Word -> [SWord 8] -> SWord 32
-- readMemoryWord32' (C _ i) m = fromBytes $ truncpad 4 (drop (num i) m)

-- setMemoryWord' :: Word -> SymWord -> [SWord 8] -> [SWord 8]
-- setMemoryWord' (C _ i) (S _ x) =
--   writeMemory' (toBytes x) 32 0 (num i)

-- setMemoryByte' :: Word -> SWord 8 -> [SWord 8] -> [SWord 8]
-- setMemoryByte' (C _ i) x =
--   writeMemory' [x] 1 0 (num i)

readSWord'' :: SymWord -> SList (WordN 8) -> SymWord
readSWord'' (S _ i) x =
  ite (sFromIntegral i .> SL.length x)
  0
  (swordAt' (sFromIntegral i) x)

-- * Operations over buffers (concrete or symbolic)

-- | A buffer is a list of bytes, and is used to model EVM memory or calldata.
-- During concrete execution, this is simply `ByteString`.
-- In symbolic settings, the structure of a buffer is sometimes known statically,
-- in which case simply use a list of symbolic bytes.
-- When we are dealing with dynamically determined calldata or memory (such as if
-- we are interpreting a function which a `memory bytes` argument),
-- we use smt lists. Note that smt lists are not yet supported by cvc4!
data Buffer
  = ConcreteBuffer ByteString
  | StaticSymBuffer [SWord 8]
  | DynamicSymBuffer (SList (WordN 8))
  deriving (Show)

dynamize :: Buffer -> SList (WordN 8)
dynamize (ConcreteBuffer a)  = SL.implode $ litBytes a
dynamize (StaticSymBuffer a) = SL.implode a
dynamize (DynamicSymBuffer a) = a

instance EqSymbolic Buffer where
  ConcreteBuffer a .== ConcreteBuffer b = literal (a == b)
  ConcreteBuffer a .== StaticSymBuffer b = litBytes a .== b
  StaticSymBuffer a .== ConcreteBuffer b = a .== litBytes b
  StaticSymBuffer a .== StaticSymBuffer b = a .== b
  a .== b = dynamize a .== dynamize b


instance Semigroup Buffer where
  ConcreteBuffer a     <> ConcreteBuffer b   = ConcreteBuffer (a <> b)
  ConcreteBuffer a     <> StaticSymBuffer b  = StaticSymBuffer (litBytes a <> b)
  c@(ConcreteBuffer a) <> DynamicSymBuffer b = DynamicSymBuffer (dynamize c .++ b)

  StaticSymBuffer a     <> ConcreteBuffer b   = StaticSymBuffer (a <> litBytes b)
  StaticSymBuffer a     <> StaticSymBuffer b  = StaticSymBuffer (a <> b)
  c@(StaticSymBuffer a) <> DynamicSymBuffer b = DynamicSymBuffer (dynamize c .++ b)

  a <> b = DynamicSymBuffer (dynamize a .++ dynamize b)

instance Monoid Buffer where
  mempty = ConcreteBuffer mempty

-- a whole foldable instance seems overkill, but length is always good to have!
len :: Buffer -> SWord 32
len (DynamicSymBuffer a) = sFromIntegral $ SL.length a
len (StaticSymBuffer bs) = literal . num $ length bs
len (ConcreteBuffer bs) = literal . num $ BS.length bs

grab :: Int -> Buffer -> Buffer
grab n (StaticSymBuffer bs) = StaticSymBuffer $ take n bs
grab n (ConcreteBuffer bs) = ConcreteBuffer $ BS.take n bs
grab n (DynamicSymBuffer bs) = DynamicSymBuffer $ SL.take (literal $ num n) bs

ditch :: Int -> Buffer -> Buffer
ditch n (StaticSymBuffer bs) = StaticSymBuffer $ drop n bs
ditch n (ConcreteBuffer bs) = ConcreteBuffer $ BS.drop n bs
ditch n (DynamicSymBuffer bs) = DynamicSymBuffer $ SL.drop (literal $ num n) bs

readByteOrZero :: Int -> Buffer -> SWord 8
readByteOrZero i (StaticSymBuffer bs) = readByteOrZero' i bs
readByteOrZero i (ConcreteBuffer bs) = num $ Concrete.readByteOrZero i bs
readByteOrZero i (DynamicSymBuffer bs) = readByteOrZero'' (literal $ num i) bs

sliceWithZero :: SymWord -> SymWord -> Buffer -> Buffer
sliceWithZero o s bf = case (maybeLitWord o, maybeLitWord s, bf) of
  (Just o', Just s', StaticSymBuffer m) -> StaticSymBuffer (sliceWithZero' (num o') (num s') m)
  (Just o', Just s', ConcreteBuffer m) -> ConcreteBuffer (Concrete.byteStringSliceWithDefaultZeroes (num o') (num s') m)
sliceWithZero o s (StaticSymBuffer bf) = DynamicSymBuffer $ sliceWithZero'' o s (SL.implode bf)
sliceWithZero o s (ConcreteBuffer bf) = DynamicSymBuffer $ sliceWithZero'' o s (SL.implode (litBytes bf))
sliceWithZero o s (DynamicSymBuffer bf) = DynamicSymBuffer $ sliceWithZero'' o s bf

writeMemory :: Buffer -> SymWord -> SymWord -> SymWord -> Buffer -> Buffer
writeMemory bs1 n src dst bs0 =
  case (maybeLitWord n, maybeLitWord src, maybeLitWord dst, bs0, bs1) of
    (Just n', Just src', Just dst', ConcreteBuffer bs0', ConcreteBuffer bs1') ->
      ConcreteBuffer $ Concrete.writeMemory bs0' n' src' dst' bs1'
    (Just n', Just src', Just dst', StaticSymBuffer bs0', ConcreteBuffer bs1') ->
      StaticSymBuffer $ writeMemory' bs0' n' src' dst' (litBytes bs1')
    (Just n', Just src', Just dst', ConcreteBuffer bs0', StaticSymBuffer bs1') ->
      StaticSymBuffer $ writeMemory' (litBytes bs0') n' src' dst' bs1'
    (Just n', Just src', Just dst', StaticSymBuffer bs0', StaticSymBuffer bs1') ->
      StaticSymBuffer $ writeMemory' bs0' n' src' dst' bs1'
    _ -> let bs0' = dynamize bs0
             bs1' = dynamize bs1
         in DynamicSymBuffer $ dynWriteMemory bs0' n src dst bs1'

readMemoryWord :: Word -> Buffer -> SymWord
readMemoryWord i (StaticSymBuffer m) = readMemoryWord' i m
readMemoryWord i (ConcreteBuffer m) = litWord $ Concrete.readMemoryWord i m

readMemoryWord32 :: Word -> Buffer -> SWord 32
readMemoryWord32 i (StaticSymBuffer m) = readMemoryWord32' i m
readMemoryWord32 i (ConcreteBuffer m) = num $ Concrete.readMemoryWord32 i m

setMemoryWord :: Word -> SymWord -> Buffer -> Buffer
setMemoryWord i x (StaticSymBuffer z) = StaticSymBuffer $ setMemoryWord' i x z
setMemoryWord i x (ConcreteBuffer z) = case maybeLitWord x of
  Just x' -> ConcreteBuffer $ Concrete.setMemoryWord i x' z
  Nothing -> StaticSymBuffer $ setMemoryWord' i x (litBytes z)

setMemoryByte :: Word -> SWord 8 -> Buffer -> Buffer
setMemoryByte i x (StaticSymBuffer m) = StaticSymBuffer $ setMemoryByte' i x m
setMemoryByte i x (ConcreteBuffer m) = case fromSized <$> unliteral x of
  Nothing -> StaticSymBuffer $ setMemoryByte' i x (litBytes m)
  Just x' -> ConcreteBuffer $ Concrete.setMemoryByte i x' m

readSWord :: SymWord -> Buffer -> SymWord
readSWord i bf = case (maybeLitWord i, bf) of
  (Just i', StaticSymBuffer x) -> readSWord' i' x
  (Just i', ConcreteBuffer x) -> num $ Concrete.readMemoryWord i' x
  _  -> readSWord'' i (dynamize bf)

-- | Custom instances for SymWord, many of which have direct
-- analogues for concrete words defined in Concrete.hs

instance Show SymWord where
  show s@(S Dull _) = case maybeLitWord s of
    Nothing -> "<symbolic>"
    Just w  -> show w
  show (S (Var var) x) = var ++ ": " ++ show x
  show (S (InfixBinOp symbol x y) z) = show x ++ symbol ++ show y  ++ ": " ++ show z
  show (S (BinOp symbol x y) z) = symbol ++ show x ++ show y  ++ ": " ++ show z
  show (S (UnOp symbol x) z) = symbol ++ show x ++ ": " ++ show z
  show (S whiff x) = show whiff ++ ": " ++ show x

instance EqSymbolic SymWord where
  (.==) (S _ x) (S _ y) = x .== y

instance Num SymWord where
  (S _ x) + (S _ y) = sw256 (x + y)
  (S _ x) * (S _ y) = sw256 (x * y)
  abs (S _ x) = sw256 (abs x)
  signum (S _ x) = sw256 (signum x)
  fromInteger x = sw256 (fromInteger x)
  negate (S _ x) = sw256 (negate x)

instance Bits SymWord where
  (S _ x) .&. (S _ y) = sw256 (x .&. y)
  (S _ x) .|. (S _ y) = sw256 (x .|. y)
  (S _ x) `xor` (S _ y) = sw256 (x `xor` y)
  complement (S _ x) = sw256 (complement x)
  shift (S _ x) i = sw256 (shift x i)
  rotate (S _ x) i = sw256 (rotate x i)
  bitSize (S _ x) = bitSize x
  bitSizeMaybe (S _ x) = bitSizeMaybe x
  isSigned (S _ x) = isSigned x
  testBit (S _ x) i = testBit x i
  bit i = sw256 (bit i)
  popCount (S _ x) = popCount x

instance SDivisible SymWord where
  sQuotRem (S _ x) (S _ y) = let (a, b) = x `sQuotRem` y
                             in (sw256 a, sw256 b)
  sDivMod (S _ x) (S _ y) = let (a, b) = x `sDivMod` y
                             in (sw256 a, sw256 b)

instance Mergeable SymWord where
  symbolicMerge a b (S _ x) (S _ y) = sw256 $ symbolicMerge a b x y
  select xs (S _ x) b = let ys = fmap (\(S _ y) -> y) xs
                        in sw256 $ select ys x b

instance Bounded SymWord where
  minBound = sw256 minBound
  maxBound = sw256 maxBound

instance Eq SymWord where
  (S _ x) == (S _ y) = x == y

instance Enum SymWord where
  toEnum i = sw256 (toEnum i)
  fromEnum (S _ x) = fromEnum x

instance OrdSymbolic SymWord where
  (.<) (S _ x) (S _ y) = (.<) x y
