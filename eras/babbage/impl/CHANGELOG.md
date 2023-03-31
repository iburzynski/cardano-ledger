# Version history for `cardano-ledger-babbage`

## 1.1.0.0

* Add `ToJSON` instance for `BabbageTxOut`.
* Add `ToJSON` instance for `BabbagePParams Identity` and `BabbagePParams StrictMaybe`
* Removed validation function `validateOutputTooBigUTxO`, in favor of the same function
  from `cardano-ledger-alonzo`.
* Added support for Plutus V3 in the types and functions that use `Language`.
  (Note that the Alonzo ledger era rules do not allow V3 scripts, however.).

###`testlib`

* Consolidate all `Arbitrary` instances from the test package to under a new `testlib`. #3285

## 1.0.0.0

* First properly versioned release.
