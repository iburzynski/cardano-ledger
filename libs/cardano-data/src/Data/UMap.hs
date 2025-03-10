{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}

-- | A 'UMap' (for Unified map) represents 3 Maps of the same size in one direction,
--   and a fourth one in the inverse direction.
--   The advantage of using 'UMap' is that 'UMap' stores all the information compactly, by exploiting the
--   the large amount of sharing in the 2 maps.
module Data.UMap (
  -- * Constructing 'UMap'
  -- $UMAP
  Trip (Triple),
  tripReward,
  tripRewardActiveDelegation,
  tripDelegation,
  UMap (..),
  umInvariant,

  -- * View and its components
  -- $VIEW
  View (..),
  unView,
  unUnify,
  viewToVMap,
  rewView,
  delView,
  ptrView,
  domRestrictedView,
  zero,
  zeroMaybe,

  -- * Operations to implement the 'Iter' class
  -- $ITER
  mapNext,
  mapLub,
  next,
  leastUpperBound,

  -- * Set and Map operations on Views
  -- $VIEWOPS
  empty,
  delete,
  delete',
  insertWith,
  insertWith',
  insert,
  insert',
  lookup,
  isNull,
  domain,
  range,
  (∪),
  (⨃),
  (∪+),
  (⋪),
  (⋫),
  member,
  notMember,
  domRestrict,

  -- * Runtime evidence of a View
  -- $Tag
  Tag (..),
  UnifiedView (..),
  --  * Derived functions
  --  $DFUNS
  findWithDefault,
  size,
  unify,
)
where

import Cardano.Ledger.Binary
import Cardano.Ledger.TreeDiff (ToExpr)
import Control.DeepSeq (NFData (..))
import Control.Monad.Trans.State.Strict (StateT (..))
import Data.Foldable (Foldable (..))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.MapExtras (intersectDomPLeft)
import Data.Maybe as Maybe (fromMaybe, isNothing, mapMaybe)
import Data.Maybe.Strict (StrictMaybe (..))
import Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Set.Internal as SI (Set (..))
import Data.Typeable (Typeable)
import qualified Data.VMap as VMap
import GHC.Generics (Generic)
import NoThunks.Class (NoThunks (..))
import Prelude hiding (lookup)

-- ===================================================================
-- UMAP

-- | a 'Trip' compactly represents the range of 3 maps with the same domain as a single triple.
--   The space compacting Trip datatype, and the pattern Triple are equivalent to:
--
-- @
-- data Trip coin ptr pool = Triple
--   { coinT :: !(StrictMaybe coin),
--     ptrT :: !(Set ptr),
--     poolidT :: !(StrictMaybe pool)
--   }
--  deriving (Show, Eq, Generic, NoThunks, NFData)
-- @
--
-- To name the constructors of 'Trip' we use the notation @Txxx@ where each @x@ is either
-- @F@ for full, i.e. the component is present, or @E@ for empty,
-- the component  is not present. There are three components
-- 1) the coin, 2) the Ptr set, and 3) the PoolID. so TEEE means none of the
-- components are present, and TEEF means only the PoolId is present. etc.
-- The pattern 'Triple' will correctly use the optimal constructor.
data Trip coin ptr pool
  = TEEE
  | TEEF !pool
  | TEFE !(Set ptr)
  | TEFF !(Set ptr) !pool
  | TFEE !coin
  | TFEF !coin !pool
  | TFFE !coin !(Set ptr)
  | TFFF !coin !(Set ptr) !pool
  deriving (Eq, Ord, Generic, NoThunks, NFData)

-- | We can view all of the constructors as a Triple.
viewTrip :: Trip coin ptr pool -> (StrictMaybe coin, Set ptr, StrictMaybe pool)
viewTrip TEEE = (SNothing, Set.empty, SNothing)
viewTrip (TEEF x) = (SNothing, Set.empty, SJust x)
viewTrip (TEFE x) = (SNothing, x, SNothing)
viewTrip (TEFF x y) = (SNothing, x, SJust y)
viewTrip (TFEE x) = (SJust x, Set.empty, SNothing)
viewTrip (TFEF x y) = (SJust x, Set.empty, SJust y)
viewTrip (TFFE x y) = (SJust x, y, SNothing)
viewTrip (TFFF x y z) = (SJust x, y, SJust z)

-- | Extract the active delegation, if it is present. We can tell that the delegation
--   is present when Txxx has an F in the 1st and 3rd positions. I.e. TFFF and TFEF
--                                                                     ^ ^      ^ ^
--  equivalent to the pattern (Triple (SJust c) _ (SJust _)) -> Just c
tripRewardActiveDelegation :: Trip coin ptr pool -> Maybe coin
tripRewardActiveDelegation =
  \case
    TFFF c _ _ -> Just c
    TFEF c _ -> Just c
    _ -> Nothing

-- | Extract the Reward 'Coin' if it is present. We can tell that the reward is
--   present when Txxx has an F in the first position TFFF TFFE TFEF TFEE
--                                                     ^    ^    ^    ^
--  equivalent to the pattern (Triple (SJust c) _ _) -> Just c
tripReward :: Trip coin ptr pool -> Maybe coin
tripReward =
  \case
    TFFF c _ _ -> Just c
    TFFE c _ -> Just c
    TFEF c _ -> Just c
    TFEE c -> Just c
    _ -> Nothing

-- | Extract the Delegation PoolParams, if present. We can tell that the PoolParams are
--   present when Txxx has an F in the third position TFFF TFEF TEFF TEEF
--                                                       ^    ^    ^    ^
--  equivalent to the pattern (Triple _ _ (SJust p)) -> Just p
tripDelegation :: Trip coin ptr pool -> Maybe pool
tripDelegation =
  \case
    TFFF _ _ p -> Just p
    TFEF _ p -> Just p
    TEFF _ p -> Just p
    TEEF p -> Just p
    _ -> Nothing

-- | A Triple can be extracted and injected into the TEEE ... TFFF constructors.
pattern Triple :: StrictMaybe coin -> Set ptr -> StrictMaybe pool -> Trip coin ptr pool
pattern Triple a b c <-
  (viewTrip -> (a, b, c))
  where
    Triple a b c =
      case (a, b, c) of
        (SNothing, SI.Tip, SNothing) -> TEEE
        (SNothing, SI.Tip, SJust x) -> TEEF x
        (SNothing, x, SNothing) -> TEFE x
        (SNothing, x, SJust y) -> TEFF x y
        (SJust x, SI.Tip, SNothing) -> TFEE x
        (SJust x, SI.Tip, SJust y) -> TFEF x y
        (SJust x, y, SNothing) -> TFFE x y
        (SJust x, y, SJust z) -> TFFF x y z

{-# COMPLETE Triple #-}

instance (Show coin, Show pool, Show ptr) => Show (Trip coin ptr pool) where
  show (Triple a b c) = "(Triple " ++ show a ++ " " ++ show b ++ " " ++ show c ++ ")"

-- =====================================================

-- | A unified map represents three Maps of the same size in one direction with @cred@ for
--   keys and one more in the inverse direction with @ptr@ for keys and @cred@ for values.
data UMap coin cred pool ptr = UnifiedMap !(Map cred (Trip coin ptr pool)) !(Map ptr cred)
  deriving (Show, Eq, Generic, NoThunks, NFData)

-- | It is worthwhie stating the invariant that holds on a Unified Map
--   The 'ptrmap' and the 'ptrT' field of the 'tripmap' are inverses.
umInvariant :: (Ord cred, Ord ptr) => cred -> ptr -> UMap coin cred pool ptr -> Bool
umInvariant stake ptr (UnifiedMap tripmap ptrmap) = forwards && backwards
  where
    forwards =
      case Map.lookup stake tripmap of
        Nothing -> all (stake /=) ptrmap
        Just (Triple _c set _d) ->
          if Set.member ptr set
            then case Map.lookup ptr ptrmap of
              Nothing -> False
              Just stake2 -> stake == stake2
            else True
    backwards =
      case Map.lookup ptr ptrmap of
        Nothing -> all (\(Triple _ set _) -> Set.notMember ptr set) tripmap
        Just cred ->
          case Map.lookup cred tripmap of
            Nothing -> False
            Just (Triple _ set _) -> Set.member ptr set

-- =====================================================

-- VIEW

-- | A 'View' lets one view a 'UMap' in three different ways
--   A view with type @(View coin cred poolparam ptr key value)@ can be used like a @(Map key value)@
data View coin cr pl ptr k v where
  Rewards ::
    !(UMap coin cr pl ptr) ->
    View coin cr pl ptr cr coin
  Delegations ::
    !(UMap coin cr pl ptr) ->
    View coin cr pl ptr cr pl
  Ptrs ::
    !(UMap coin cr pl ptr) ->
    View coin cr pl ptr ptr cr

-- ==================================================
-- short hand constructors and selectors

rewards ::
  Map cr (Trip coin ptr pool) ->
  Map ptr cr ->
  View coin cr pool ptr cr coin
rewards x y = Rewards (UnifiedMap x y)

delegations ::
  Map cred (Trip coin ptr pool) ->
  Map ptr cred ->
  View coin cred pool ptr cred pool
delegations x y = Delegations (UnifiedMap x y)

ptrs ::
  Map cred (Trip coin ptr pool) ->
  Map ptr cred ->
  View coin cred pool ptr ptr cred
ptrs x y = Ptrs (UnifiedMap x y)

-- | Extract the underlying 'UMap' from a 'View'
unView :: View coin cr pl ptr k v -> UMap coin cr pl ptr
unView (Rewards um) = um
unView (Delegations um) = um
unView (Ptrs um) = um

-- | Materialize a real 'Map' from a 'View'
--   This is expensive, use it wisely (like maybe once per epoch boundary to make a SnapShot)
--   See also domRestrictedView, which domain restricts before computing a view.
unUnify :: View coin cred pool ptr k v -> Map k v
unUnify (Rewards (UnifiedMap tripmap _)) = Map.mapMaybe tripReward tripmap
unUnify (Delegations (UnifiedMap tripmap _)) = Map.mapMaybe tripDelegation tripmap
unUnify (Ptrs (UnifiedMap _ ptrmap)) = ptrmap

-- | Materialize a real Vector Map from a 'View'
--   This is expensive, use it wisely (like maybe once per epoch boundary to make a SnapShot)
viewToVMap :: Ord cred => View coin cred pool ptr k v -> VMap.VMap VMap.VB VMap.VB k v
viewToVMap view =
  case view of
    Rewards (UnifiedMap tripmap _) ->
      VMap.fromListN (size view) . Maybe.mapMaybe toReward . Map.toList $ tripmap
    Delegations (UnifiedMap tripmap _) ->
      VMap.fromListN (size view) . Maybe.mapMaybe toDelegation . Map.toList $ tripmap
    Ptrs (UnifiedMap _ ptrmap) -> VMap.fromMap ptrmap
  where
    toReward (key, t) = (,) key <$> tripReward t
    toDelegation (key, t) = (,) key <$> tripDelegation t

-- | Materialize the Rewards Map from a 'UMap'
rewView :: UMap coin cred pool ptr -> Map.Map cred coin
rewView x = unUnify (Rewards x)

-- | Materialize the Delegation Map from a 'UMap'
delView :: UMap coin cred pool ptr -> Map.Map cred pool
delView x = unUnify (Delegations x)

-- | Materialize the Ptr Map from a 'UMap'
ptrView :: UMap coin cred pool ptr -> Map.Map ptr cred
ptrView x = unUnify (Ptrs x)

-- | Return the appropriate View of a domain restricted Umap. f 'setk' is small this should be efficient.
domRestrictedView :: (Ord ptr, Ord cred) => Set k -> View coin cred pl ptr k v -> Map.Map k v
domRestrictedView setk (Rewards (UnifiedMap tripmap _)) =
  Map.mapMaybe tripReward (Map.restrictKeys tripmap setk)
domRestrictedView setk (Delegations (UnifiedMap tripmap _)) =
  Map.mapMaybe tripDelegation (Map.restrictKeys tripmap setk)
domRestrictedView setk (Ptrs (UnifiedMap _ ptrmap)) = Map.restrictKeys ptrmap setk

-- | All 3 'Views' are 'Foldable'
instance Foldable (View coin cred pool ptr k) where
  foldMap f (Rewards (UnifiedMap tmap _)) = Map.foldlWithKey accum mempty tmap
    where
      accum ans _ (Triple (SJust c) _ _) = ans <> f c
      accum ans _ _ = ans
  foldMap f (Delegations (UnifiedMap tmap _)) = Map.foldlWithKey accum mempty tmap
    where
      accum ans _ (Triple _ _ (SJust c)) = ans <> f c
      accum ans _ (Triple _ _ SNothing) = ans
  foldMap f (Ptrs (UnifiedMap _ ptrmap)) = foldMap f ptrmap
  foldr accum ans0 (Rewards (UnifiedMap tmap _)) = Map.foldr accum2 ans0 tmap
    where
      accum2 (Triple (SJust c) _ _) ans = accum c ans
      accum2 _ ans = ans
  foldr accum ans0 (Delegations (UnifiedMap tmap _)) = Map.foldr accum2 ans0 tmap
    where
      accum2 (Triple _ _ (SJust c)) ans = accum c ans
      accum2 (Triple _ _ SNothing) ans = ans
  foldr accum ans (Ptrs (UnifiedMap _ ptrmap)) = Map.foldr accum ans ptrmap

  foldl' accum ans0 (Rewards (UnifiedMap tmap _)) = Map.foldl' accum2 ans0 tmap
    where
      accum2 ans = maybe ans (accum ans) . tripReward
  foldl' accum ans0 (Delegations (UnifiedMap tmap _)) = Map.foldl' accum2 ans0 tmap
    where
      accum2 ans = maybe ans (accum ans) . tripDelegation
  foldl' accum ans (Ptrs (UnifiedMap _ ptrmap)) = Map.foldl' accum ans ptrmap
  length = size

-- =======================================================
-- Operations on Triple

instance (Ord ptr, Monoid coin) => Semigroup (Trip coin ptr pool) where
  (<>) (Triple c1 ptrs1 x) (Triple c2 ptrs2 y) =
    Triple (appendStrictMaybe c1 c2) (Set.union ptrs1 ptrs2) (add x y)
    where
      add SNothing SNothing = SNothing
      add (SJust w) SNothing = SJust w
      add SNothing (SJust z) = SJust z
      add (SJust w) (SJust _) = SJust w

appendStrictMaybe :: Monoid x => StrictMaybe x -> StrictMaybe x -> StrictMaybe x
appendStrictMaybe SNothing SNothing = SNothing
appendStrictMaybe (SJust w) SNothing = SJust w
appendStrictMaybe SNothing (SJust z) = SJust z
appendStrictMaybe (SJust c1) (SJust c2) = SJust (c1 <> c2)

instance (Ord ptr, Monoid coin) => Monoid (Trip coin ptr pool) where
  mempty = Triple SNothing Set.empty SNothing

-- | Is there no information in a Triple? If so then we can delete it from the UnifedMap
zero :: Trip coin ptr pool -> Bool
zero (Triple SNothing s SNothing) | Set.null s = True
zero _ = False

zeroMaybe :: Trip coin ptr pool -> Maybe (Trip coin ptr pool)
zeroMaybe t | zero t = Nothing
zeroMaybe t = Just t

-- ===============================================================
-- Iter Operations

-- ITER

mapNext :: Map k v -> Maybe (k, v, Map k v)
mapNext m =
  case Map.minViewWithKey m of
    Nothing -> Nothing
    Just ((k, v), m2) -> Just (k, v, m2)

mapLub :: Ord k => k -> Map k v -> Maybe (k, v, Map k v)
mapLub k m =
  case Map.splitLookup k m of
    (_, Nothing, m2) -> mapNext m2
    (_, Just v, m2) -> Just (k, v, m2)

next :: View coin cr pl ptr k v -> Maybe (k, v, View coin cr pl ptr k v)
next (Rewards (UnifiedMap tripmap _)) =
  case mapNext tripmap of
    Nothing -> Nothing
    Just (k, Triple (SJust coin) _ _, tripmap2) -> Just (k, coin, rewards tripmap2 Map.empty)
    Just (_, Triple SNothing _ _, tripmap2) -> next (rewards tripmap2 Map.empty)
next (Delegations (UnifiedMap tripmap _)) =
  case mapNext tripmap of
    Nothing -> Nothing
    Just (k, Triple _ _ (SJust poolid), tripmap2) -> Just (k, poolid, delegations tripmap2 Map.empty)
    Just (_, Triple _ _ SNothing, tripmap2) -> next (delegations tripmap2 Map.empty)
next (Ptrs (UnifiedMap tripmap ptrmap)) =
  case mapNext ptrmap of
    Nothing -> Nothing
    Just (k, stakeid, m2) -> Just (k, stakeid, ptrs (Map.empty `asTypeOf` tripmap) m2)

leastUpperBound ::
  (Ord ptr, Ord cr) =>
  k ->
  View coin cr pool ptr k v ->
  Maybe (k, v, View coin cr pool ptr k v)
leastUpperBound stakeid (Rewards (UnifiedMap tripmap _)) =
  case mapLub stakeid tripmap of
    Nothing -> Nothing
    Just (k, Triple (SJust coin) _ _, tripmap2) -> Just (k, coin, rewards tripmap2 Map.empty)
    Just (_, Triple SNothing _ _, tripmap2) -> next (rewards tripmap2 Map.empty)
leastUpperBound stakeid (Delegations (UnifiedMap tripmap _)) =
  case mapLub stakeid tripmap of
    Nothing -> Nothing
    Just (k, Triple _ _ (SJust poolid), tripmap2) -> Just (k, poolid, delegations tripmap2 Map.empty)
    Just (_, Triple _ _ SNothing, tripmap2) -> next (Delegations (UnifiedMap tripmap2 Map.empty))
leastUpperBound ptr (Ptrs (UnifiedMap tripmap ptrmap)) =
  case mapLub ptr ptrmap of
    Nothing -> Nothing
    Just (k, stakeid, m2) -> Just (k, stakeid, ptrs (Map.empty `asTypeOf` tripmap) m2)

-- ==============================================================
-- Basic operations on ViewMap

-- VIEWOPS

empty :: UMap coin cr pool ptr
empty = UnifiedMap Map.empty Map.empty

delete' ::
  (Ord cr, Ord ptr) =>
  k ->
  View coin cr pool ptr k v ->
  View coin cr pool ptr k v
delete' stakeid (Rewards (UnifiedMap tripmap ptrmap)) =
  rewards (Map.update ok stakeid tripmap) ptrmap
  where
    ok (Triple _ ptr poolid) = zeroMaybe (Triple SNothing ptr poolid)
delete' stakeid (Delegations (UnifiedMap tripmap ptrmap)) =
  delegations (Map.update ok stakeid tripmap) ptrmap
  where
    ok (Triple c ptr _) = zeroMaybe (Triple c ptr SNothing)
delete' ptr (Ptrs (UnifiedMap tripmap ptrmap)) =
  case Map.lookup ptr ptrmap of
    Nothing -> Ptrs (UnifiedMap tripmap ptrmap)
    Just stakeid -> ptrs (Map.update ok stakeid tripmap) (Map.delete ptr ptrmap)
      where
        ok (Triple coin ptrset poolid) = zeroMaybe (Triple coin (Set.delete ptr ptrset) poolid)

delete :: (Ord cr, Ord ptr) => k -> View coin cr pool ptr k v -> UMap coin cr pool ptr
delete k m = unView (delete' k m)

-- | Special insertion:
--
--  Keeps the value already in the ViewMap if the key 'k' is already there:
--
-- > insertWith' (\ old new -> old) k v xs
--
-- Replaces the value already in the ViewMap with 'v', if key 'k' is already there:
--
-- > insertWith' (\ old new -> new) k v xs
--
-- Replaces the value already in the ViewMap with the sum, if key 'k' is already there:
--
-- > insertWith' (\ old new -> old+new) k v xs
--
-- Ignores 'combine' if the key 'k' is NOT already in the ViewMap, and inserts 'v':
--
-- > insertWith' combine k v xs
insertWith' ::
  (Ord cr, Monoid coin, Ord ptr) =>
  (v -> v -> v) ->
  k ->
  v ->
  View coin cr pool ptr k v ->
  View coin cr pool ptr k v
insertWith' comb stakeid newcoin (Rewards (UnifiedMap tripmap ptrmap)) =
  rewards (Map.alter comb2 stakeid tripmap) ptrmap
  where
    comb2 Nothing = Just (Triple (SJust newcoin) Set.empty SNothing)
    comb2 (Just (Triple (SJust oldcoin) x y)) = zeroMaybe (Triple (SJust (comb oldcoin newcoin)) x y)
    comb2 (Just (Triple SNothing x y)) = zeroMaybe (Triple (SJust newcoin) x y)
insertWith' comb stakeid newpoolid (Delegations (UnifiedMap tripmap ptrmap)) =
  delegations (Map.alter comb2 stakeid tripmap) ptrmap
  where
    comb2 Nothing = Just (Triple SNothing Set.empty (SJust newpoolid))
    comb2 (Just (Triple x y (SJust old))) = Just (Triple x y (SJust (comb old newpoolid)))
    comb2 (Just (Triple x y SNothing)) = Just (Triple x y (SJust newpoolid))
insertWith' comb ptr stake (Ptrs (UnifiedMap tripmap ptrmap)) =
  let (oldstake, newstake) =
        case Map.lookup ptr ptrmap of -- This is tricky, because we need to retract the oldstake
          Nothing -> (stake, stake) -- and to add the newstake to maintain the UnifiedMap invariant
          Just stake2 -> (stake2, comb stake2 stake)
      -- Delete pointer from set in Triple, but also delete the whole triple if it goes to Zero.
      retract stakeid pointer m = Map.update ok stakeid m
        where
          ok (Triple c set d) = zeroMaybe (Triple c (Set.delete pointer set) d)
      add stakeid pointer m =
        Map.insertWith (<>) stakeid (Triple SNothing (Set.singleton pointer) SNothing) m
      tripmap2 = add newstake ptr (retract oldstake ptr tripmap)
      ptrmap2 = Map.insert ptr newstake ptrmap
   in Ptrs (UnifiedMap tripmap2 ptrmap2)

insertWith ::
  (Ord cr, Monoid coin, Ord ptr) =>
  (v -> v -> v) ->
  k ->
  v ->
  View coin cr pool ptr k v ->
  UMap coin cr pool ptr
insertWith comb k v m = unView (insertWith' comb k v m)

insert' ::
  (Ord cr, Monoid coin, Ord ptr) =>
  k ->
  v ->
  View coin cr pool ptr k v ->
  View coin cr pool ptr k v
insert' = insertWith' (\_old new -> new)

insert ::
  (Ord cr, Monoid coin, Ord ptr) =>
  k ->
  v ->
  View coin cr pool ptr k v ->
  UMap coin cr pool ptr
insert k v m = unView (insert' k v m)

lookup :: (Ord cr, Ord ptr) => k -> View coin cr pool ptr k v -> Maybe v
lookup stakeid (Rewards (UnifiedMap tripmap _)) =
  Map.lookup stakeid tripmap >>= tripReward
lookup stakeid (Delegations (UnifiedMap tripmap _)) =
  Map.lookup stakeid tripmap >>= tripDelegation
lookup ptr (Ptrs (UnifiedMap _ ptrmap)) = Map.lookup ptr ptrmap

isNull :: View coin cr pool ptr k v -> Bool
isNull (Rewards (UnifiedMap tripmap _)) = all (isNothing . tripReward) tripmap
isNull (Delegations (UnifiedMap tripmap _)) = all (isNothing . tripDelegation) tripmap
isNull (Ptrs (UnifiedMap _ ptrmap)) = Map.null ptrmap

domain :: (Ord cr) => View coin cr pool ptr k v -> Set k
domain (Rewards (UnifiedMap tripmap _)) = Map.foldlWithKey' accum Set.empty tripmap
  where
    accum ans k (Triple (SJust _) _ _) = Set.insert k ans
    accum ans _ _ = ans
domain (Delegations (UnifiedMap tripmap _)) = Map.foldlWithKey' accum Set.empty tripmap
  where
    accum ans k (Triple _ _ (SJust _)) = Set.insert k ans
    accum ans _k (Triple _ _ SNothing) = ans
domain (Ptrs (UnifiedMap _ ptrmap)) = Map.keysSet ptrmap

range :: (Ord coin, Ord pool, Ord cr) => View coin cr pool ptr k v -> Set v
range (Rewards (UnifiedMap tripmap _)) = Map.foldlWithKey' accum Set.empty tripmap
  where
    accum ans _ (Triple (SJust coin) _ _) = Set.insert coin ans
    accum ans _ _ = ans
range (Delegations (UnifiedMap tripmap _)) = Map.foldlWithKey' accum Set.empty tripmap
  where
    accum ans _ (Triple _ _ (SJust v)) = Set.insert v ans
    accum ans _ (Triple _ _ SNothing) = ans
range (Ptrs (UnifiedMap _tripmap ptrmap)) =
  Set.fromList (Map.elems ptrmap) -- tripmap is the inverse of ptrmap

-- =============================================================
-- evalUnified (Rewards u1 ∪ singleton hk mempty)
-- evalUnified (Ptrs u2 ∪ singleton ptr hk)

-- | Union with left preference, so if k, already exists, do nothing, if it doesn't exist insert it.
(∪) ::
  ( Ord cr
  , Monoid coin
  , Ord ptr
  ) =>
  View coin cr pool ptr k v ->
  (k, v) ->
  UMap coin cr pool ptr
view ∪ (k, v) = insertWith (\old _new -> old) k v view

-- ======================================
-- evalUnified  (delegations ds ⨃ singleton hk dpool) })
-- evalUnified (rewards' ⨃ wdrls_')

-- | Union with right preference, so if 'k', already exists, then its value is overwritten with 'v'
(⨃) ::
  ( Ord cr
  , Monoid coin
  , Ord ptr
  ) =>
  View coin cr pool ptr k v ->
  Map k v ->
  UMap coin cr pool ptr
view ⨃ mp = unView $ Map.foldlWithKey' accum view mp
  where
    accum ans k v = insertWith' (\_old new -> new) k v ans

-- ==========================================
-- evalUnified (rewards dState ∪+ registeredAggregated)
-- evalUnified (rewards' ∪+ update)
-- evalUnified  (Rewards u0 ∪+ refunds)

(∪+) ::
  ( Ord cred
  , Monoid coin
  ) =>
  View coin cred pool ptr k coin ->
  Map k coin ->
  UMap coin cred pool ptr
(Rewards (UnifiedMap tm pm)) ∪+ mp = UnifiedMap (unionHelp tm mp) pm
(Delegations (UnifiedMap tm pm)) ∪+ _mp = UnifiedMap tm pm -- I don't think this is reachable
(Ptrs (UnifiedMap tm pm)) ∪+ _mp = UnifiedMap tm pm -- I don't think this is reachable

unionHelp ::
  (Ord k, Monoid coin) =>
  Map k (Trip coin ptr pool) ->
  Map k coin ->
  Map k (Trip coin ptr pool)
unionHelp tm mm =
  Map.mergeWithKey
    (\_k (Triple c1 s d) c2 -> Just (Triple (appendStrictMaybe c1 (SJust c2)) s d))
    id
    (Map.map TFEE) -- Note TFEE = (\c -> Triple (SJust c) Set.empty SNothing)
    tm
    mm

-- ============================================
-- evalUnified (setSingleton hk ⋪ Rewards u0)
-- evalUnified (setSingleton hk ⋪ Delegations u1)

(⋪) ::
  (Ord cred, Ord ptr) =>
  Set k ->
  View coin cred pool ptr k v ->
  UMap coin cred pool ptr
set ⋪ view = unView (Set.foldl' (flip delete') view set)

-- ============================================
-- evalUnified (Ptrs u2 ⋫ setSingleton hk)
-- evalUnified (Delegations u1 ⋫ retired)

-- | This is slow for Delegations and Rewards Views, better hope they are small
(⋫) ::
  (Ord cred, Ord ptr, Ord coin, Ord pool) =>
  View coin cred pool ptr k v ->
  Set v ->
  UMap coin cred pool ptr
Ptrs um ⋫ set = Set.foldl' removeCredStaking um set
  where
    -- removeCredStaking :: UnifiedMap crypto -> Credential 'Staking crypto -> UnifiedMap crypto
    removeCredStaking m@(UnifiedMap m2 m1) cred =
      case Map.lookup cred m2 of
        Just (Triple _ kset _) ->
          UnifiedMap (Map.update ok cred m2) (foldr (\k pset -> Map.delete k pset) m1 kset)
          where
            ok (Triple coin _ poolid) = zeroMaybe (Triple coin Set.empty poolid)
        Nothing -> m
Delegations (UnifiedMap tmap pmap) ⋫ delegset = UnifiedMap (Map.foldlWithKey' accum tmap tmap) pmap
  where
    ok (Triple c set _) = zeroMaybe (Triple c set SNothing)
    accum ans _key (Triple _ _ SNothing) = ans
    accum ans key (Triple _ _ (SJust d)) =
      if Set.member d delegset
        then Map.update ok key ans
        else ans
Rewards (UnifiedMap tmap pmap) ⋫ coinset = UnifiedMap (Map.foldlWithKey' accum tmap tmap) pmap
  where
    ok (Triple _ set d) = zeroMaybe (Triple SNothing set d)
    accum ans key (Triple (SJust coin) _ _) =
      if Set.member coin coinset
        then Map.update ok key ans
        else ans
    accum ans _ _ = ans

-- =============================================

-- eval (k ∈ dom (rewards dState))
-- eval (k ∈ dom (rewards ds)))
-- eval (hk ∈ dom (rewards ds))
-- eval (hk ∉ dom (rewards ds))

member :: (Ord cr, Ord ptr) => k -> View coin cr pool ptr k v -> Bool
member k (Rewards (UnifiedMap tmap _)) =
  case Map.lookup k tmap of
    Just (Triple (SJust _) _ _) -> True
    _ -> False
member k (Delegations (UnifiedMap tmap _)) =
  case Map.lookup k tmap of
    Just (Triple _ _ (SJust _)) -> True
    _ -> False
member k (Ptrs (UnifiedMap _ pmap)) = Map.member k pmap

notMember :: (Ord cr, Ord ptr) => k -> View coin cr pool ptr k v -> Bool
notMember k um = not (member k um)

-- =====================================================

-- eval (dom rewards' ◁ iRReserves (_irwd ds) :: RewardAccounts (Crypto era))
-- eval (dom rewards' ◁ iRTreasury (_irwd ds) :: RewardAccounts (Crypto era))

domRestrict :: (Ord cr, Ord ptr) => View coin cr pool ptr k v -> Map k u -> Map k u
domRestrict (Rewards (UnifiedMap tmap _)) m = intersectDomPLeft p m tmap
  where
    p _ (Triple (SJust _) _ _) = True
    p _ _ = False
domRestrict (Delegations (UnifiedMap tmap _)) m = intersectDomPLeft p m tmap
  where
    p _ (Triple _ _ (SJust _)) = True
    p _ _ = False
domRestrict (Ptrs (UnifiedMap _ pmap)) m = Map.intersection m pmap

-- ==========================

type Tbor x = (Typeable x, EncCBOR x)

instance
  (Tbor coin, Tbor ptr, Ord ptr, EncCBOR pool) =>
  EncCBOR (Trip coin ptr pool)
  where
  encCBOR (Triple coin ptr pool) =
    encodeListLen 3 <> encCBOR coin <> encCBOR ptr <> encCBOR pool

instance
  (DecCBOR coin, Ord ptr, DecCBOR ptr, DecCBOR pool) =>
  DecShareCBOR (Trip coin ptr pool)
  where
  type Share (Trip coin ptr pool) = Interns pool
  decShareCBOR is =
    decodeRecordNamed "Triple" (const 3) $
      do
        a <- decCBOR
        b <- decCBOR
        c <- decShareMonadCBOR is
        pure (Triple a b c)

instance
  (Tbor coin, Tbor ptr, Tbor cred, EncCBOR pool, Ord ptr) =>
  EncCBOR (UMap coin cred pool ptr)
  where
  encCBOR (UnifiedMap tripmap ptrmap) =
    encodeListLen 2 <> encodeMap encCBOR encCBOR tripmap <> encodeMap encCBOR encCBOR ptrmap

instance
  (Ord cred, DecCBOR cred, Ord ptr, DecCBOR ptr, DecCBOR coin, DecCBOR pool) =>
  DecShareCBOR (UMap coin cred pool ptr)
  where
  type
    Share (UMap coin cred pool ptr) =
      (Interns cred, Interns pool)
  decSharePlusCBOR =
    StateT
      ( \(a, b) ->
          decodeRecordNamed "UnifiedMap" (const 2) $ do
            tripmap <- decodeMap (interns a <$> decCBOR) (decShareCBOR b)
            let a' = internsFromMap tripmap <> a
            ptrmap <- decodeMap decCBOR (interns a' <$> decCBOR)
            pure (UnifiedMap tripmap ptrmap, (a', b))
      )

-- =================================================================

-- ===================================================
-- Tag

data Tag coin cred pool ptr k v where
  Rew :: Tag coin cred pool ptr cred coin
  Del :: Tag coin cred pool ptr cred pool
  Ptr :: Tag coin cred pool ptr ptr cred

class UnifiedView coin cred pool ptr k v where
  tag :: Tag coin cred pool ptr k v

-- ==================================================
-- derived operations

-- DFUNS

-- | Find the value associated with a key from a View, return the default if the key is not there.
findWithDefault :: (Ord cred, Ord ptr) => a -> k -> View coin cred pool ptr k a -> a
findWithDefault d k = fromMaybe d . lookup k

-- | A View is a view, so the size of the view is NOT the same as the size of
-- the underlying triple map.
size :: View coin cred pool ptr k a -> Int
size (Ptrs (UnifiedMap _ ptrmap)) = Map.size ptrmap
size x = foldl' (\count _v -> count + 1) 0 x

-- | Create a UMap from 3 separate maps. For use in tests only.
unify ::
  (Monoid coin, Ord cred, Ord ptr) =>
  Map cred coin ->
  Map cred pool ->
  Map ptr cred ->
  UMap coin cred pool ptr
unify rews dels ptrss = um3
  where
    um1 = unView $ Map.foldlWithKey' (\um k v -> insert' k v um) (Rewards empty) rews
    um2 = unView $ Map.foldlWithKey' (\um k v -> insert' k v um) (Delegations um1) dels
    um3 = unView $ Map.foldlWithKey' (\um k v -> insert' k v um) (Ptrs um2) ptrss

-- =====================================================

instance (ToExpr a, ToExpr b, ToExpr c, ToExpr d) => ToExpr (UMap a b c d)

instance (ToExpr a, ToExpr b, ToExpr c) => ToExpr (Trip a b c)
