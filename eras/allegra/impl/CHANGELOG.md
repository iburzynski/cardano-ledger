# Version history for `cardano-ledger-allegra`

## 1.2.0.0

* Replace `DPState c` with `CertState era`
* Parametrize `DState` and `PState` by era
* Add `TranslateEra` instances for:
  * `DState`
  * `PState`
  * `VState`

## 1.1.0.0

* Remove redundant pattern synonym `AllegraTxAuxData'`
* Hide internal `AllegraTxAuxDataRaw` constructor with `atadrMetadata` and `atadrTimelock`
  record fields.

### `testlib`

* Consolidate all `Arbitrary` instances from the test package to under a new `testlib`. #3285

## 1.0.0.0

* First properly versioned release.
