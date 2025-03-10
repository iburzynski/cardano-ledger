{-# LANGUAGE TypeApplications #-}

module Test.Cardano.Ledger.Babbage.TxInfo where

import Cardano.Ledger.Address (Addr (..), BootstrapAddress (..))
import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Alonzo.Language (Language (..))
import Cardano.Ledger.Alonzo.PParams ()
import Cardano.Ledger.Alonzo.Scripts.Data (Data (..), dataToBinaryData)
import Cardano.Ledger.Alonzo.Tx (AlonzoTx (..), IsValid (..))
import Cardano.Ledger.Alonzo.TxInfo (
  TranslationError (..),
  TxOutSource (..),
  VersionedTxInfo (..),
  txInfo,
 )
import Cardano.Ledger.Babbage (Babbage)
import Cardano.Ledger.Babbage.TxBody (BabbageTxBody (..), BabbageTxOut (..), Datum (..))
import Cardano.Ledger.Babbage.TxInfo (txInfoInV2, txInfoOutV2)
import Cardano.Ledger.BaseTypes (Network (..), StrictMaybe (..))
import Cardano.Ledger.Binary (mkSized)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core hiding (TranslationError)
import Cardano.Ledger.Credential (StakeReference (..))
import Cardano.Ledger.Shelley.TxBody (Withdrawals (..))
import Cardano.Ledger.TxIn (TxIn (..), mkTxInPartial)
import Cardano.Ledger.UTxO (UTxO (..))
import qualified Cardano.Ledger.Val as Val
import Cardano.Slotting.EpochInfo (EpochInfo, fixedEpochInfo)
import Cardano.Slotting.Slot (EpochSize (..))
import Cardano.Slotting.Time (SystemStart (..), mkSlotLength)
import Data.Default.Class (def)
import qualified Data.Map.Strict as Map
import qualified Data.Sequence.Strict as StrictSeq
import qualified Data.Set as Set
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import GHC.Stack
import qualified PlutusLedgerApi.V1 as PV1
import qualified PlutusLedgerApi.V2 as PV2
import Test.Cardano.Ledger.Alonzo.Arbitrary (alwaysSucceeds)
import Test.Cardano.Ledger.EraBuffet (StandardCrypto)
import Test.Cardano.Ledger.Shelley.Address.Bootstrap (aliceByronAddr)
import Test.Cardano.Ledger.Shelley.Examples.Cast (alicePHK)
import Test.Cardano.Ledger.Shelley.Generator.EraGen (genesisId)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))

byronAddr :: Addr StandardCrypto
byronAddr = AddrBootstrap (BootstrapAddress aliceByronAddr)

shelleyAddr :: Addr StandardCrypto
shelleyAddr = Addr Testnet alicePHK StakeRefNull

ei :: EpochInfo (Either a)
ei = fixedEpochInfo (EpochSize 100) (mkSlotLength 1)

ss :: SystemStart
ss = SystemStart $ posixSecondsToUTCTime 0

-- This input is only a "Byron input" in the sense
-- that we attach it to a Byron output in the UTxO created below.
byronInput :: TxIn StandardCrypto
byronInput = mkTxInPartial genesisId 0

-- This input is only unknown in the sense
-- that it is not present in the UTxO created below.
unknownInput :: TxIn StandardCrypto
unknownInput = mkTxInPartial genesisId 1

byronOutput :: TxOut Babbage
byronOutput = BabbageTxOut byronAddr (Val.inject $ Coin 1) NoDatum SNothing

shelleyOutput :: TxOut Babbage
shelleyOutput = BabbageTxOut shelleyAddr (Val.inject $ Coin 2) NoDatum SNothing

datumEx :: Datum Babbage
datumEx = Datum . dataToBinaryData . Data . PV1.I $ 123

inlineDatumOutput :: TxOut Babbage
inlineDatumOutput = BabbageTxOut shelleyAddr (Val.inject $ Coin 3) datumEx SNothing

refScriptOutput :: TxOut Babbage
refScriptOutput = BabbageTxOut shelleyAddr (Val.inject $ Coin 3) NoDatum (SJust $ alwaysSucceeds PlutusV2 3)

-- This input is only a "Shelley input" in the sense
-- that we attach it to a Shelley output in the UTxO created below.
shelleyInput :: TxIn StandardCrypto
shelleyInput = mkTxInPartial genesisId 2

inputWithInlineDatum :: TxIn StandardCrypto
inputWithInlineDatum = mkTxInPartial genesisId 3

inputWithRefScript :: TxIn StandardCrypto
inputWithRefScript = mkTxInPartial genesisId 4

utxo :: UTxO Babbage
utxo =
  UTxO $
    Map.fromList
      [ (byronInput, byronOutput)
      , (shelleyInput, shelleyOutput)
      , (inputWithInlineDatum, inlineDatumOutput)
      , (inputWithRefScript, refScriptOutput)
      ]

txb :: TxIn StandardCrypto -> Maybe (TxIn StandardCrypto) -> TxOut Babbage -> TxBody Babbage
txb i mRefInp o =
  BabbageTxBody
    { btbInputs = Set.singleton i
    , btbCollateral = mempty
    , btbReferenceInputs = maybe mempty Set.singleton mRefInp
    , btbOutputs = StrictSeq.singleton (mkSized (eraProtVerHigh @Babbage) o)
    , btbCollateralReturn = SNothing
    , btbTotalCollateral = SNothing
    , btbCerts = mempty
    , btbWithdrawals = Withdrawals mempty
    , btbTxFee = Coin 2
    , btbValidityInterval = ValidityInterval SNothing SNothing
    , btbUpdate = SNothing
    , btbReqSignerHashes = mempty
    , btbMint = mempty
    , btbScriptIntegrityHash = SNothing
    , btbAuxDataHash = SNothing
    , btbTxNetworkId = SNothing
    }

txBare :: TxIn StandardCrypto -> TxOut Babbage -> AlonzoTx Babbage
txBare i o = AlonzoTx (txb i Nothing o) mempty (IsValid True) SNothing

txRefInput :: TxIn StandardCrypto -> AlonzoTx Babbage
txRefInput refInput =
  AlonzoTx (txb shelleyInput (Just refInput) shelleyOutput) mempty (IsValid True) SNothing

hasReferenceInput :: VersionedTxInfo -> Bool
hasReferenceInput (TxInfoPV1 _) = False
hasReferenceInput (TxInfoPV2 info) = PV2.txInfoReferenceInputs info /= mempty

expectOneInput :: PV2.TxInInfo -> VersionedTxInfo -> Bool
expectOneInput _ (TxInfoPV1 _) = False
expectOneInput i (TxInfoPV2 info) = PV2.txInfoInputs info == [i]

expectOneOutput :: PV2.TxOut -> VersionedTxInfo -> Bool
expectOneOutput _ (TxInfoPV1 _) = False
expectOneOutput o (TxInfoPV2 info) = PV2.txInfoOutputs info == [o]

successfulTranslation :: Language -> AlonzoTx Babbage -> (VersionedTxInfo -> Bool) -> Assertion
successfulTranslation lang tx f =
  case ctx of
    Right info -> assertBool "unexpected transaction info" (f info)
    Left e -> assertFailure $ "no translation error was expected, but got: " <> show e
  where
    ctx = txInfo def lang ei ss utxo tx

successfulV2Translation :: AlonzoTx Babbage -> (VersionedTxInfo -> Bool) -> Assertion
successfulV2Translation = successfulTranslation PlutusV2

expectTranslationError :: Language -> AlonzoTx Babbage -> TranslationError StandardCrypto -> Assertion
expectTranslationError lang tx expected =
  case ctx of
    Right _ -> assertFailure "This translation was expected to fail, but it succeeded."
    Left e -> e @?= expected
  where
    ctx = txInfo def lang ei ss utxo tx

expectV1TranslationError :: AlonzoTx Babbage -> TranslationError StandardCrypto -> Assertion
expectV1TranslationError = expectTranslationError PlutusV1

expectV2TranslationError :: AlonzoTx Babbage -> TranslationError StandardCrypto -> Assertion
expectV2TranslationError = expectTranslationError PlutusV2

errorTranslate :: (HasCallStack, Show a) => String -> Either a b -> b
errorTranslate exampleName =
  either (\err -> error $ exampleName ++ " failed: " ++ show err) id

translatedInputEx1 :: PV2.TxInInfo
translatedInputEx1 =
  errorTranslate "translatedInputEx1" $ txInfoInV2 utxo inputWithInlineDatum

translatedInputEx2 :: PV2.TxInInfo
translatedInputEx2 =
  errorTranslate "translatedInputEx2" $ txInfoInV2 utxo inputWithRefScript

translatedOutputEx1 :: PV2.TxOut
translatedOutputEx1 =
  errorTranslate "translatedOutputEx1" $ txInfoOutV2 (TxOutFromOutput minBound) inlineDatumOutput

translatedOutputEx2 :: PV2.TxOut
translatedOutputEx2 =
  errorTranslate "translatedOutputEx2" $ txInfoOutV2 (TxOutFromOutput minBound) refScriptOutput

txInfoTests :: TestTree
txInfoTests =
  testGroup
    "txInfo translation"
    [ testGroup
        "Plutus V1"
        [ testCase "translation error on byron txout" $
            expectV1TranslationError
              (txBare shelleyInput byronOutput)
              (ByronTxOutInContext (TxOutFromOutput minBound))
        , testCase "translation error on byron txin" $
            expectV1TranslationError
              (txBare byronInput shelleyOutput)
              (ByronTxOutInContext (TxOutFromInput byronInput))
        , testCase "translation error on unknown txin (logic error)" $
            expectV1TranslationError
              (txBare unknownInput shelleyOutput)
              (TranslationLogicMissingInput unknownInput)
        , testCase "translation error on reference input" $
            expectV1TranslationError
              (txRefInput shelleyInput)
              (ReferenceInputsNotSupported (Set.singleton shelleyInput))
        , testCase "translation error on inline datum in input" $
            expectV1TranslationError
              (txBare inputWithInlineDatum shelleyOutput)
              (InlineDatumsNotSupported (TxOutFromInput inputWithInlineDatum))
        , testCase "translation error on inline datum in output" $
            expectV1TranslationError
              (txBare shelleyInput inlineDatumOutput)
              (InlineDatumsNotSupported (TxOutFromOutput minBound))
        , testCase "translation error on reference script in input" $
            expectV1TranslationError
              (txBare inputWithRefScript shelleyOutput)
              (ReferenceScriptsNotSupported (TxOutFromInput inputWithRefScript))
        , testCase "translation error on reference script in output" $
            expectV1TranslationError
              (txBare shelleyInput refScriptOutput)
              (ReferenceScriptsNotSupported (TxOutFromOutput minBound))
        ]
    , testGroup
        "Plutus V2"
        [ testCase "translation error on byron txout" $
            expectV2TranslationError
              (txBare shelleyInput byronOutput)
              (ByronTxOutInContext (TxOutFromOutput minBound))
        , testCase "translation error on byron txin" $
            expectV2TranslationError
              (txBare byronInput shelleyOutput)
              (ByronTxOutInContext (TxOutFromInput byronInput))
        , testCase "translation error on unknown txin (logic error)" $
            expectV2TranslationError
              (txBare unknownInput shelleyOutput)
              (TranslationLogicMissingInput unknownInput)
        , testCase "use reference input in Babbage" $
            successfulV2Translation
              (txRefInput shelleyInput)
              hasReferenceInput
        , testCase "use inline datum in input" $
            successfulV2Translation
              (txBare inputWithInlineDatum shelleyOutput)
              (expectOneInput translatedInputEx1)
        , testCase "use inline datum in output" $
            successfulV2Translation
              (txBare shelleyInput inlineDatumOutput)
              (expectOneOutput translatedOutputEx1)
        , testCase "use reference script in input" $
            successfulV2Translation
              (txBare inputWithRefScript shelleyOutput)
              (expectOneInput translatedInputEx2)
        , testCase "use reference script in output" $
            successfulV2Translation
              (txBare shelleyInput refScriptOutput)
              (expectOneOutput translatedOutputEx2)
        ]
    ]
