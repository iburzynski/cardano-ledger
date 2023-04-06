# Version history for `cardano-ledger-conway`

## 1.2.0.0

* Added `ConwayDelegCert` #3372
* Removed `toShelleyDCert` and `fromShelleyDCertMaybe` #3372

## 1.1.0.0

* Added `RATIFY` rule
* Added `GovernanceActionMetadata`
* Added `RatifyEnv` and `RatifySignal`
* Added lenses:
  * `cgTallyL`
  * `cgRatifyL`
  * `cgVoterRolesL`
* Removed `GovernanceActionInfo`
* Removed `Vote`
* Replaced `ctbrVotes` and `ctbrGovActions` with `ctbrGovProcedure`
* Renamed `ENACTMENT` to `ENACT`

## 1.0.0.0

* First properly versioned release.
