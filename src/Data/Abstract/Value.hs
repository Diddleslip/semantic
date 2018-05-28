{-# LANGUAGE GADTs, RankNTypes, TypeOperators, UndecidableInstances #-}
module Data.Abstract.Value where

import Control.Abstract hiding (Label)
import Data.Abstract.Environment (Environment, emptyEnv, mergeEnvs)
import qualified Data.Abstract.Environment as Env
import Data.Abstract.Name
import qualified Data.Abstract.Number as Number
import Data.List (genericIndex, genericLength)
import Data.Scientific (Scientific)
import Data.Scientific.Exts
import Data.Semigroup.Reducer
import qualified Data.Set as Set
import Prologue

data Value location term
  = Closure PackageInfo ModuleInfo [Name] ClosureBody (Environment location)
  | Unit
  | Boolean Bool
  | Integer  (Number.Number Integer)
  | Rational (Number.Number Rational)
  | Float    (Number.Number Scientific)
  | String ByteString
  | Symbol ByteString
  | Tuple [Value location term]
  | Array [Value location term]
  | Class Name (Environment location)
  | Namespace Name (Environment location)
  | KVPair (Value location term) (Value location term)
  | Hash [Value location term]
  | Null
  | Hole
  deriving (Eq, Ord, Show)

data ClosureBody = Label Int
  deriving (Eq, Show, Ord)


instance Ord location => ValueRoots location (Value location term) where
  valueRoots v
    | Closure _ _ _ _ env <- v = Env.addresses env
    | otherwise                = mempty


instance AbstractHole (Value location term) where
  hole = Hole

instance ( Members '[ Allocator location (Value location term)
                    , Reader (Environment location)
                    , Reader ModuleInfo
                    , Reader PackageInfo
                    , Resumable (ValueError location term)
                    , Return (Value location term)
                    , State (Environment location)
                    , State (Heap location (Cell location) (Value location term))
                    ] effects
         , Ord location
         , Reducer (Value location term) (Cell location (Value location term))
         , Show location
         )
      => AbstractFunction location (Value location term) (Goto effects (Value location term) ': effects) where
  closure parameters freeVariables body = do
    packageInfo <- currentPackage
    moduleInfo <- currentModule
    l <- label body
    Closure packageInfo moduleInfo parameters (Label l) . Env.bind (foldr Set.delete freeVariables parameters) <$> getEnv

  call op params = do
    case op of
      Closure packageInfo moduleInfo names (Label label) env -> do
        body <- goto label
        -- Evaluate the bindings and body with the closure’s package/module info in scope in order to
        -- charge them to the closure's origin.
        withCurrentPackage packageInfo . withCurrentModule moduleInfo $ do
          bindings <- foldr (\ (name, param) rest -> do
            v <- param
            a <- alloc name
            assign a v
            Env.insert name a <$> rest) (pure env) (zip names params)
          localEnv (mergeEnvs bindings) (body `catchReturn` \ (Return value) -> pure value)
      _ -> throwValueError (CallError op)


-- | Construct a 'Value' wrapping the value arguments (if any).
instance ( Members '[ Allocator location (Value location term)
                    , LoopControl (Value location term)
                    , Reader (Environment location)
                    , Reader ModuleInfo
                    , Reader PackageInfo
                    , Resumable (ValueError location term)
                    , Return (Value location term)
                    , State (Environment location)
                    , State (Heap location (Cell location) (Value location term))
                    ] effects
         , Ord location
         , Reducer (Value location term) (Cell location (Value location term))
         , Show location
         )
      => AbstractValue location (Value location term) (Goto effects (Value location term) ': effects) where
  unit     = pure Unit
  integer  = pure . Integer . Number.Integer
  boolean  = pure . Boolean
  string   = pure . String
  float    = pure . Float . Number.Decimal
  symbol   = pure . Symbol
  rational = pure . Rational . Number.Ratio

  multiple = pure . Tuple
  array    = pure . Array

  kvPair k = pure . KVPair k

  null     = pure Null

  asPair val
    | KVPair k v <- val = pure (k, v)
    | otherwise = throwValueError $ KeyValueError val

  hash = pure . Hash . map (uncurry KVPair)

  klass n [] env = pure $ Class n env
  klass n supers env = do
    product <- foldl mergeEnvs emptyEnv . catMaybes <$> traverse scopedEnvironment supers
    pure $ Class n (mergeEnvs product env)

  namespace n env = do
    maybeAddr <- lookupEnv n
    env' <- maybe (pure emptyEnv) (asNamespaceEnv <=< deref) maybeAddr
    pure (Namespace n (Env.mergeNewer env' env))
    where asNamespaceEnv v
            | Namespace _ env' <- v = pure env'
            | otherwise             = throwValueError $ NamespaceError ("expected " <> show v <> " to be a namespace")

  scopedEnvironment o
    | Class _ env <- o = pure (Just env)
    | Namespace _ env <- o = pure (Just env)
    | otherwise = pure Nothing

  asString v
    | String n <- v = pure n
    | otherwise     = throwValueError $ StringError v

  ifthenelse cond if' else' = do
    bool <- case cond of { Boolean b -> pure b ; _ -> throwValueError (BoolError cond) }
    if bool then if' else else'

  index = go where
    tryIdx list ii
      | ii > genericLength list = throwValueError (BoundsError list ii)
      | otherwise               = pure (genericIndex list ii)
    go arr idx
      | (Array arr, Integer (Number.Integer i)) <- (arr, idx) = tryIdx arr i
      | (Tuple tup, Integer (Number.Integer i)) <- (arr, idx) = tryIdx tup i
      | otherwise = throwValueError (IndexError arr idx)

  liftNumeric f arg
    | Integer (Number.Integer i) <- arg = integer $ f i
    | Float (Number.Decimal d)   <- arg = float   $ f d
    | Rational (Number.Ratio r)  <- arg = rational $ f r
    | otherwise = throwValueError (NumericError arg)

  liftNumeric2 f left right
    | (Integer  i, Integer j)  <- pair = tentative f i j & specialize
    | (Integer  i, Rational j) <- pair = tentative f i j & specialize
    | (Integer  i, Float j)    <- pair = tentative f i j & specialize
    | (Rational i, Integer j)  <- pair = tentative f i j & specialize
    | (Rational i, Rational j) <- pair = tentative f i j & specialize
    | (Rational i, Float j)    <- pair = tentative f i j & specialize
    | (Float    i, Integer j)  <- pair = tentative f i j & specialize
    | (Float    i, Rational j) <- pair = tentative f i j & specialize
    | (Float    i, Float j)    <- pair = tentative f i j & specialize
    | otherwise = throwValueError (Numeric2Error left right)
      where
        tentative x i j = attemptUnsafeArithmetic (x i j)

        -- Dispatch whatever's contained inside a 'Number.SomeNumber' to its appropriate 'MonadValue' ctor
        specialize :: (AbstractValue location (Value location term) effects, Member (Resumable (ValueError location term)) effects) => Either ArithException Number.SomeNumber -> Evaluator location (Value location term) effects (Value location term)
        specialize (Left exc) = throwValueError (ArithmeticError exc)
        specialize (Right (Number.SomeNumber (Number.Integer i))) = integer i
        specialize (Right (Number.SomeNumber (Number.Ratio r)))   = rational r
        specialize (Right (Number.SomeNumber (Number.Decimal d))) = float d
        pair = (left, right)

  liftComparison comparator left right
    | (Integer (Number.Integer i), Integer (Number.Integer j)) <- pair = go i j
    | (Integer (Number.Integer i), Float   (Number.Decimal j)) <- pair = go (fromIntegral i) j
    | (Float   (Number.Decimal i), Integer (Number.Integer j)) <- pair = go i                (fromIntegral j)
    | (Float   (Number.Decimal i), Float   (Number.Decimal j)) <- pair = go i j
    | (String  i,                  String  j)                  <- pair = go i j
    | (Boolean i,                  Boolean j)                  <- pair = go i j
    | (Unit,                       Unit)                       <- pair = boolean True
    | otherwise = throwValueError (ComparisonError left right)
      where
        -- Explicit type signature is necessary here because we're passing all sorts of things
        -- to these comparison functions.
        go :: (AbstractValue location (Value location term) effects, Ord a) => a -> a -> Evaluator location (Value location term) effects (Value location term)
        go l r = case comparator of
          Concrete f  -> boolean (f l r)
          Generalized -> integer (orderingToInt (compare l r))

        -- Map from [LT, EQ, GT] to [-1, 0, 1]
        orderingToInt :: Ordering -> Prelude.Integer
        orderingToInt = toInteger . pred . fromEnum

        pair = (left, right)


  liftBitwise operator target
    | Integer (Number.Integer i) <- target = integer $ operator i
    | otherwise = throwValueError (BitwiseError target)

  liftBitwise2 operator left right
    | (Integer (Number.Integer i), Integer (Number.Integer j)) <- pair = integer $ operator i j
    | otherwise = throwValueError (Bitwise2Error left right)
      where pair = (left, right)

  loop x = catchLoopControl (fix x) (\ control -> case control of
    Break value -> pure value
    -- FIXME: Figure out how to deal with this. Ruby treats this as the result of the current block iteration, while PHP specifies a breakout level and TypeScript appears to take a label.
    Continue _  -> loop x)


-- | The type of exceptions that can be thrown when constructing values in 'Value'’s 'MonadValue' instance.
data ValueError location term resume where
  StringError            :: Value location term                        -> ValueError location term ByteString
  BoolError              :: Value location term                        -> ValueError location term Bool
  IndexError             :: Value location term -> Value location term -> ValueError location term (Value location term)
  NamespaceError         :: Prelude.String                             -> ValueError location term (Environment location)
  CallError              :: Value location term                        -> ValueError location term (Value location term)
  NumericError           :: Value location term                        -> ValueError location term (Value location term)
  Numeric2Error          :: Value location term -> Value location term -> ValueError location term (Value location term)
  ComparisonError        :: Value location term -> Value location term -> ValueError location term (Value location term)
  BitwiseError           :: Value location term                        -> ValueError location term (Value location term)
  Bitwise2Error          :: Value location term -> Value location term -> ValueError location term (Value location term)
  KeyValueError          :: Value location term                        -> ValueError location term (Value location term, Value location term)
  -- Indicates that we encountered an arithmetic exception inside Haskell-native number crunching.
  ArithmeticError        :: ArithException                             -> ValueError location term (Value location term)
  -- Out-of-bounds error
  BoundsError            :: [Value location term] -> Prelude.Integer   -> ValueError location term (Value location term)


instance Eq location => Eq1 (ValueError location term) where
  liftEq _ (StringError a) (StringError b)                       = a == b
  liftEq _ (NamespaceError a) (NamespaceError b)                 = a == b
  liftEq _ (CallError a) (CallError b)                           = a == b
  liftEq _ (BoolError a) (BoolError c)                           = a == c
  liftEq _ (IndexError a b) (IndexError c d)                     = (a == c) && (b == d)
  liftEq _ (Numeric2Error a b) (Numeric2Error c d)               = (a == c) && (b == d)
  liftEq _ (ComparisonError a b) (ComparisonError c d)           = (a == c) && (b == d)
  liftEq _ (Bitwise2Error a b) (Bitwise2Error c d)               = (a == c) && (b == d)
  liftEq _ (BitwiseError a) (BitwiseError b)                     = a == b
  liftEq _ (KeyValueError a) (KeyValueError b)                   = a == b
  liftEq _ (BoundsError a b) (BoundsError c d)                   = (a == c) && (b == d)
  liftEq _ _             _                                       = False

deriving instance Show location => Show (ValueError location term resume)
instance Show location => Show1 (ValueError location term) where
  liftShowsPrec _ _ = showsPrec

throwValueError :: Member (Resumable (ValueError location term)) effects => ValueError location term resume -> Evaluator location (Value location term) effects resume
throwValueError = throwResumable

runValueError :: TermEvaluator term location (Value location term) (Resumable (ValueError location term) ': effects) a -> TermEvaluator term location (Value location term) effects (Either (SomeExc (ValueError location term)) a)
runValueError = runResumable

runValueErrorWith :: Effectful (m location (Value location term)) => (forall resume . ValueError location term resume -> m location (Value location term) effects resume) -> m location (Value location term) (Resumable (ValueError location term) ': effects) a -> m location (Value location term) effects a
runValueErrorWith = runResumableWith
