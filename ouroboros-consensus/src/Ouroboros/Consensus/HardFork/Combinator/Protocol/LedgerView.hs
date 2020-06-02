{-# LANGUAGE StandaloneDeriving #-}

module Ouroboros.Consensus.HardFork.Combinator.Protocol.LedgerView (
    -- * Single era
    HardForkEraLedgerView_(..)
  , HardForkEraLedgerView
  , mkHardForkEraLedgerView
    -- * Hard fork
  , HardForkLedgerView_
  , HardForkLedgerView
  ) where

import           Data.SOP.Strict

import           Ouroboros.Consensus.Ledger.Abstract
import           Ouroboros.Consensus.Ledger.SupportsProtocol
import           Ouroboros.Consensus.TypeFamilyWrappers

import           Ouroboros.Consensus.HardFork.Combinator.Abstract
import           Ouroboros.Consensus.HardFork.Combinator.Basics
import           Ouroboros.Consensus.HardFork.Combinator.PartialConfig
import           Ouroboros.Consensus.HardFork.Combinator.State.Infra
                     (HardForkState_, TransitionOrTip (..))
import qualified Ouroboros.Consensus.HardFork.Combinator.State.Infra as State

{-------------------------------------------------------------------------------
  Ledger view for single era
-------------------------------------------------------------------------------}

data HardForkEraLedgerView_ f blk = HardForkEraLedgerView {
      -- | Transition to the next era or the tip of the ledger otherwise
      --
      -- NOTE: When forecasting a view, this is set to the /actual/ tip of the
      -- ledger, not the forecast slot number. It is this tip that determines
      -- where the safe zone starts, and that should not vary with the slot
      -- of the forecast.
      --
      -- Indeed, it is even possible that this tip is in a /previous/ era.
      hardForkEraTransition :: !TransitionOrTip

      -- | Underlying ledger view
    , hardForkEraLedgerView :: !(f blk)
    }

type HardForkEraLedgerView = HardForkEraLedgerView_ WrapLedgerView

deriving instance Show (f blk) => Show (HardForkEraLedgerView_ f blk)

mkHardForkEraLedgerView :: SingleEraBlock blk
                        => EpochInfo Identity
                        -> WrapPartialLedgerConfig blk
                        -> LedgerState blk
                        -> HardForkEraLedgerView blk
mkHardForkEraLedgerView ei pcfg st = HardForkEraLedgerView {
      hardForkEraLedgerView = WrapLedgerView $
        protocolLedgerView (completeLedgerConfig' ei pcfg) st
    , hardForkEraTransition =
        State.transitionOrTip pcfg st
    }

{-------------------------------------------------------------------------------
  HardForkLedgerView
-------------------------------------------------------------------------------}

type HardForkLedgerView_ f = HardForkState_ (K ()) (HardForkEraLedgerView_ f)
type HardForkLedgerView    = HardForkLedgerView_ WrapLedgerView
