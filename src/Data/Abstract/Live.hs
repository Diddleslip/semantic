{-# LANGUAGE DataKinds, GeneralizedNewtypeDeriving, TypeFamilies, TypeOperators #-}
module Data.Abstract.Live where

import Data.Abstract.Address
import Data.Semilattice.Lower
import Data.Set as Set
import Prologue
import Unsafe.Coerce

-- | A set of live addresses (whether roots or reachable).
newtype Live l v = Live { unLive :: Set (Address l v) }
  deriving (Eq, Foldable, Lower, Monoid, Ord, Semigroup, Show)

-- | Construct a 'Live' set containing only the given address.
liveSingleton :: Address l v -> Live l v
liveSingleton = Live . Set.singleton

-- | Insert an address into a 'Live' set.
liveInsert :: Ord l => Address l v -> Live l v -> Live l v
liveInsert addr = Live . Set.insert addr . unLive

-- | Delete an address from a 'Live' set, if present.
liveDelete :: Ord l => Address l v -> Live l v -> Live l v
liveDelete addr = Live . Set.delete addr . unLive

-- | Compute the (asymmetric) difference of two 'Live' sets, i.e. delete every element of the second set from the first set.
liveDifference :: Ord l => Live l v -> Live l v -> Live l v
liveDifference = fmap Live . (Set.difference `on` unLive)

-- | Test whether an 'Address' is in a 'Live' set.
liveMember :: Ord l => Address l v -> Live l v -> Bool
liveMember addr = Set.member addr . unLive

-- | Decompose a 'Live' set into a pair of one member address and the remaining set, or 'Nothing' if empty.
liveSplit :: Live l v -> Maybe (Address l v, Live l v)
liveSplit = fmap (second Live) . Set.minView . unLive


instance Generic1 (Live l) where
  type Rep1 (Live l)
    = D1
        ('MetaData "Live" "Data.Abstract.Live" "main" 'True)
        (C1
           ('MetaCons "Live" 'PrefixI 'True)
           (S1
              ('MetaSel
                 ('Just "unLive")
                 'NoSourceUnpackedness
                 'NoSourceStrictness
                 'DecidedLazy)
              (Set :.: Rec1 (Address l))))
  -- NB: The value type @v@ in @'Address' l v@ is phantom; 'compare'ing 'Address'es is based solely on the location type @l@. Thus, we can safely coerce the values in the 'Set' without worrying about changing its shape. However, 'Set.map' would require that we add an extra 'Ord' constraint since it needs to account for the possibility of changing the shape of the set; so we use 'unsafeCoerce' to circumvent that possibility.
  to1 = Live . unsafeCoerce . unComp1 . unM1 . unM1 . unM1
  from1 = M1 . M1 . M1 . Comp1 . unsafeCoerce . unLive

instance Ord l => Functor (Live l) where
  fmap _ = Live . unsafeCoerce . unLive

instance Eq l => Eq1 (Live l) where liftEq = genericLiftEq
instance Ord l => Ord1 (Live l) where liftCompare = genericLiftCompare
instance Show l => Show1 (Live l) where liftShowsPrec = genericLiftShowsPrec
