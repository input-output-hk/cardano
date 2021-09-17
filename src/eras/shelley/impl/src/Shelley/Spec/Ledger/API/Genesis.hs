{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Shelley.Spec.Ledger.API.Genesis where

import Cardano.Ledger.Core (EraRule)
import Cardano.Ledger.Crypto (Crypto)
import Cardano.Ledger.Shelley (ShelleyEra)
import Cardano.Ledger.Val (Val ((<->)))
import Control.State.Transition (STS (State))
import Data.Default.Class (Default, def)
import Data.Kind (Type)
import qualified Data.Map.Strict as Map
import Shelley.Spec.Ledger.API.Types
  ( AccountState (AccountState),
    Coin (Coin),
    DPState (DPState),
    DState (_genDelegs),
    EpochState (EpochState),
    GenDelegs (GenDelegs),
    LedgerState (LedgerState),
    NewEpochState (NewEpochState),
    PoolDistr (PoolDistr),
    ShelleyGenesis (sgGenDelegs, sgMaxLovelaceSupply, sgProtocolParams),
    StrictMaybe (SNothing),
    UTxOState (UTxOState),
    balance,
    genesisUTxO,
    word64ToCoin,
  )
import Shelley.Spec.Ledger.EpochBoundary (BlocksMade (..), emptySnapShots)

-- | Indicates that this era may be bootstrapped from 'ShelleyGenesis'.
class CanStartFromGenesis era where
  -- | Additional genesis configuration necessary for this era.
  type AdditionalGenesisConfig era :: Type

  type AdditionalGenesisConfig era = ()

  -- | Construct an initial state given a 'ShelleyGenesis' and any appropriate
  -- 'AdditionalGenesisConfig' for the era.
  initialState ::
    ShelleyGenesis era ->
    AdditionalGenesisConfig era ->
    NewEpochState era

instance
  ( Crypto c,
    Default (State (EraRule "PPUP" (ShelleyEra c)))
  ) =>
  CanStartFromGenesis (ShelleyEra c)
  where
  initialState sg () =
    NewEpochState
      initialEpochNo
      (BlocksMade Map.empty)
      (BlocksMade Map.empty)
      ( EpochState
          (AccountState (Coin 0) reserves)
          emptySnapShots
          ( LedgerState
              ( UTxOState
                  initialUtxo
                  (Coin 0)
                  (Coin 0)
                  def
              )
              (DPState (def {_genDelegs = GenDelegs genDelegs}) def)
          )
          pp
          pp
          def
      )
      SNothing
      (PoolDistr Map.empty)
    where
      initialEpochNo = 0
      initialUtxo = genesisUTxO sg
      reserves =
        word64ToCoin (sgMaxLovelaceSupply sg)
          <-> balance initialUtxo
      genDelegs = sgGenDelegs sg
      pp = sgProtocolParams sg
