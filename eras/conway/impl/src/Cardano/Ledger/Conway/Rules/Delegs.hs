{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Cardano.Ledger.Conway.Rules.Delegs (
  ConwayDELEGS,
  ConwayDelegsPredFailure (..),
  ConwayDelegsEvent (..),
) where

import Cardano.Ledger.BaseTypes (ShelleyBase)
import Cardano.Ledger.Conway.Core (Era (..), EraRule, EraTx)
import Cardano.Ledger.Conway.Era (ConwayCERT, ConwayDELEGS)
import Cardano.Ledger.Shelley.API (CertState, Coin, DCert, DState, DelegsEnv, DelplEnv, KeyHash, KeyRole (..), PState, RewardAcnt)
import Cardano.Ledger.Shelley.Rules (ShelleyDelegsFail, ShelleyDelplPredFailure, delegsTransition)
import qualified Cardano.Ledger.Shelley.Rules as Shelley
import Control.State.Transition.Extended (Embed (..), STS (..))
import Data.Map.Strict (Map)
import Data.Sequence (Seq)
import GHC.Generics (Generic)

data ConwayDelegsPredFailure era
  = DelegateeNotRegisteredDELEG
      !(KeyHash 'StakePool (EraCrypto era)) -- target pool which is not registered
  | WithdrawalsNotInRewardsDELEGS
      !(Map (RewardAcnt (EraCrypto era)) Coin) -- withdrawals that are missing or do not withdrawal the entire amount
  | CertFailure (PredicateFailure (EraRule "CERT" era)) -- Subtransition Failures
  deriving (Generic)

newtype ConwayDelegsEvent era = DelplEvent (Event (EraRule "CERT" era))

deriving instance Eq (PredicateFailure (EraRule "CERT" era)) => Eq (ConwayDelegsPredFailure era)

deriving instance Show (PredicateFailure (EraRule "CERT" era)) => Show (ConwayDelegsPredFailure era)

instance
  certFailure ~ PredicateFailure (EraRule "CERT" era) =>
  ShelleyDelegsFail certFailure (ConwayDelegsPredFailure era) era
  where
  delegateeNotRegisteredDELEG = DelegateeNotRegisteredDELEG
  withdrawalsNotInRewardsDELEGS = WithdrawalsNotInRewardsDELEGS
  certFailure = CertFailure

instance
  ( EraTx era
  , Signal (EraRule "CERT" era) ~ DCert (EraCrypto era)
  , State (EraRule "CERT" era) ~ CertState era
  , Environment (EraRule "CERT" era) ~ DelplEnv era
  , Embed (EraRule "CERT" era) (ConwayDELEGS era)
  , PredicateFailure (EraRule "CERT" era) ~ ShelleyDelplPredFailure era
  ) =>
  STS (ConwayDELEGS era)
  where
  type State (ConwayDELEGS era) = CertState era
  type Signal (ConwayDELEGS era) = Seq (DCert (EraCrypto era))
  type Environment (ConwayDELEGS era) = DelegsEnv era
  type BaseM (ConwayDELEGS era) = ShelleyBase
  type
    PredicateFailure (ConwayDELEGS era) =
      ConwayDelegsPredFailure era
  type Event (ConwayDELEGS era) = ConwayDelegsEvent era

  transitionRules = [delegsTransition @_ @(EraRule "CERT" era) @(ConwayDELEGS era) @(ShelleyDelplPredFailure era)]

instance
  ( Era era
  , PredicateFailure (EraRule "CERT" era) ~ Shelley.ShelleyDelplPredFailure era
  , Embed (EraRule "DELEG" era) (Shelley.ShelleyDELPL era)
  , Embed (EraRule "POOL" era) (Shelley.ShelleyDELPL era)
  , State (EraRule "DELEG" era) ~ DState era
  , State (EraRule "POOL" era) ~ PState era
  , Environment (EraRule "DELEG" era) ~ Shelley.DelegEnv era
  , Environment (EraRule "POOL" era) ~ Shelley.PoolEnv era
  , Signal (EraRule "DELEG" era) ~ DCert (EraCrypto era)
  , Signal (EraRule "POOL" era) ~ DCert (EraCrypto era)
  , Event (EraRule "CERT" era) ~ Shelley.ShelleyDelplEvent era
  ) =>
  Embed (ConwayCERT era) (ConwayDELEGS era)
  where
  wrapFailed = CertFailure
  wrapEvent = DelplEvent
