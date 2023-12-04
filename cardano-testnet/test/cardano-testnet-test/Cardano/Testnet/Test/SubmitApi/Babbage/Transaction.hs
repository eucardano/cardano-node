{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- HLINT ignore "Redundant id" -}
{- HLINT ignore "Redundant return" -}
{- HLINT ignore "Use head" -}
{- HLINT ignore "Use let" -}
{- HLINT ignore "Functor law" -}

module Cardano.Testnet.Test.SubmitApi.Babbage.Transaction
  ( hprop_transaction
  ) where

import           Cardano.Api

import           Cardano.Testnet

import           Prelude

import           Control.Monad (void)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import           System.FilePath ((</>))
import qualified System.Info as SYS

import           Hedgehog (Property, (===))
import qualified Hedgehog as H
import qualified Hedgehog.Extras.Test.Base as H
import qualified Hedgehog.Extras.Test.File as H

import qualified Cardano.Api.Ledger.Lens as A
import qualified Data.Map as Map
import           Network.HTTP.Simple
import           Testnet.Components.SPO
import qualified Testnet.Process.Run as H
import           Testnet.Process.Run
import qualified Testnet.Property.Utils as H
import           Testnet.Runtime

import qualified Cardano.Api.Ledger as L
import qualified Data.Aeson.Lens as Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as Base16
import qualified Data.ByteString.Lazy as LBS
import qualified Data.List as List
import qualified Hedgehog.Extras.Test.Golden as H
import           Lens.Micro
import           Testnet.SubmitApi
import           Text.Regex (mkRegex, subRegex)

hprop_transaction :: Property
hprop_transaction = H.integrationRetryWorkspace 0 "submit-api-babbage-transaction" $ \tempAbsBasePath' -> do
  H.note_ SYS.os
  conf@Conf { tempAbsPath } <- H.noteShowM $ mkConf tempAbsBasePath'
  let tempAbsPath' = unTmpAbsPath tempAbsPath
  work <- H.createDirectoryIfMissing $ tempAbsPath' </> "work"

  let
    sbe = ShelleyBasedEraBabbage
    era = toCardanoEra sbe
    tempBaseAbsPath = makeTmpBaseAbsPath $ TmpAbsolutePath tempAbsPath'
    options = cardanoDefaultTestnetOptions
      { cardanoNodes = cardanoDefaultTestnetNodeOptions
      , cardanoSlotLength = 0.1
      , cardanoNodeEra = AnyCardanoEra era -- TODO: We should only support the latest era and the upcoming era
      }

  TestnetRuntime
    { configurationFile
    , testnetMagic
    , poolNodes
    , wallets
    } <- cardanoTestnet options conf

  poolNode1 <- H.headM poolNodes

  poolSprocket1 <- H.noteShow $ nodeSprocket $ poolRuntime poolNode1

  execConfig <- H.mkExecConfig tempBaseAbsPath poolSprocket1

  void $ procSubmitApi
    [ "--config", configurationFile
    , "--testnet-magic", show @Int testnetMagic
    , "--socket-path", "FILEPATH"
    ]

  txbodyFp <- H.note $ work </> "tx.body"
  txbodySignedFp <- H.note $ work </> "tx.body.signed"
  txbodySignedBinFp <- H.note $ work </> "tx.body.signed.bin"
  txFailedResponseFp <- H.note $ work </> "tx.failed.response"

  void $ execCli' execConfig
    [ "babbage", "query", "utxo"
    , "--address", Text.unpack $ paymentKeyInfoAddr $ head wallets
    , "--cardano-mode"
    , "--testnet-magic", show @Int testnetMagic
    , "--out-file", work </> "utxo-1.json"
    ]

  utxo1Json <- H.leftFailM . H.readJsonFile $ work </> "utxo-1.json"
  UTxO utxo1 <- H.noteShowM $ H.noteShowM $ decodeEraUTxO sbe utxo1Json
  txin1 <- H.noteShow =<< H.headM (Map.keys utxo1)

  void $ execCli' execConfig
    [ "babbage", "transaction", "build"
    , "--testnet-magic", show @Int testnetMagic
    , "--change-address", Text.unpack $ paymentKeyInfoAddr $ head wallets
    , "--tx-in", Text.unpack $ renderTxIn txin1
    , "--tx-out", Text.unpack (paymentKeyInfoAddr (head wallets)) <> "+" <> show @Int 5_000_001
    , "--out-file", txbodyFp
    ]

  void $ execCli' execConfig
    [ "babbage", "transaction", "sign"
    , "--testnet-magic", show @Int testnetMagic
    , "--tx-body-file", txbodyFp
    , "--signing-key-file", paymentSKey $ paymentKeyInfoPair $ wallets !! 0
    , "--out-file", txbodySignedFp
    ]

  let submitApiConf = SubmitApiConf
        { tempAbsPath = unTmpAbsPath tempAbsPath
        , configPath = configurationFile
        , epochSlots = 2
        , sprocket = poolSprocket1
        , maybePort = Nothing
        , testnetMagic
        }

  withSubmitApi submitApiConf [] $ \uriBase -> do
    H.byDurationM 1 5 "Expected UTxO found" $ do
      txBodySigned <- H.leftFailM $ H.readJsonFile txbodySignedFp

      cborHex <- H.nothingFail $ txBodySigned ^? Aeson.key "cborHex" . Aeson._String

      let txBs = Base16.decodeLenient (Text.encodeUtf8 cborHex)

      H.evalIO $ BS.writeFile txbodySignedBinFp txBs

      let submitApiRequestEndpoint = "POST " <> uriBase <> "/api/submit/tx"

      request <- H.evalM $ parseRequest submitApiRequestEndpoint
        <&> setRequestBodyFile txbodySignedBinFp
        <&> setRequestHeader "Content-Type" ["application/cbor"]

      response <- H.evalM $ httpLbs request

      getResponseStatusCode response === 202

    H.byDurationM 5 30 "Expected UTxO found" $ do
      void $ execCli' execConfig
        [ "babbage", "query", "utxo"
        , "--address", Text.unpack $ paymentKeyInfoAddr $ head wallets
        , "--cardano-mode"
        , "--testnet-magic", show @Int testnetMagic
        , "--out-file", work </> "utxo-2.json"
        ]

      utxo2Json <- H.leftFailM . H.readJsonFile $ work </> "utxo-2.json"
      UTxO utxo2 <- H.noteShowM $ H.noteShowM $ decodeEraUTxO sbe utxo2Json
      txouts2 <- H.noteShow $ L.unCoin . txOutValueLovelace . txOutValue . snd <$> Map.toList utxo2

      H.assert $ 5_000_001 `List.elem` txouts2

    response <- H.byDurationM 1 5 "Expected UTxO found" $ do
      txBodySigned <- H.leftFailM $ H.readJsonFile txbodySignedFp

      cborHex <- H.nothingFail $ txBodySigned ^? Aeson.key "cborHex" . Aeson._String

      let txBs = Base16.decodeLenient (Text.encodeUtf8 cborHex)

      H.evalIO $ BS.writeFile txbodySignedBinFp txBs

      let submitApiRequestEndpoint = "POST " <> uriBase <> "/api/submit/tx"

      request <- H.evalM $ parseRequest submitApiRequestEndpoint
        <&> setRequestBodyFile txbodySignedBinFp
        <&> setRequestHeader "Content-Type" ["application/cbor"]

      response <- H.evalM $ httpLbs request

      getResponseStatusCode response === 400

      pure response

    H.evalIO $ LBS.writeFile txFailedResponseFp $ redactHashLbs $ getResponseBody response

    H.diffFileVsGoldenFile txFailedResponseFp "test/cardano-testnet-test/files/golden/tx.failed.response.golden"


redactHashLbs :: LBS.ByteString -> LBS.ByteString
redactHashLbs = id
  . LBS.fromStrict
  . Text.encodeUtf8
  . Text.pack
  . redactHashString
  . Text.unpack
  . Text.decodeUtf8
  . LBS.toStrict

redactHashString :: String -> String
redactHashString input =
  subRegex regex input "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
  where
    regexPattern = "[0-9a-fA-F]{64}"
    regex = mkRegex regexPattern

txOutValue :: TxOut ctx era -> TxOutValue era
txOutValue (TxOut _ v _ _) = v

txOutValueLovelace ::TxOutValue era -> L.Coin
txOutValueLovelace = \case
  TxOutValueShelleyBased sbe v -> v ^. A.adaAssetL sbe
  TxOutValueByron (Lovelace v) -> L.Coin v
