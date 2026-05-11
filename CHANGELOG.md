# Changelog

## 0.1.0-alpha.0 (2026-05-11)


### Features

* **nix,test:** host-native e2e harness with shared probes.py + devenv processes ⛵ ([#42](https://github.com/Klazomenai/autonity-blockscout-nixos/issues/42)) ([daa8925](https://github.com/Klazomenai/autonity-blockscout-nixos/commit/daa89253c916238e7020b360e4e9140611f999af)), closes [#35](https://github.com/Klazomenai/autonity-blockscout-nixos/issues/35)
* **nix:** autonity NixOS module ⛵ ([#5](https://github.com/Klazomenai/autonity-blockscout-nixos/issues/5)) ([e555901](https://github.com/Klazomenai/autonity-blockscout-nixos/commit/e55590188be242fa2a4e90f8c6c0a5bde4cc4eaa))
* **nix:** blockscout-backend module with LoadCredential secrets 🔐 ([#12](https://github.com/Klazomenai/autonity-blockscout-nixos/issues/12)) ([928c955](https://github.com/Klazomenai/autonity-blockscout-nixos/commit/928c9551942dea725b29f984f1648142948ee568))
* **nix:** blockscout-frontend module with declarative envs.js overlay ⛵ ([#14](https://github.com/Klazomenai/autonity-blockscout-nixos/issues/14)) ([86d5c19](https://github.com/Klazomenai/autonity-blockscout-nixos/commit/86d5c195dd53566fc5188de028ff90104e8347c0)), closes [#13](https://github.com/Klazomenai/autonity-blockscout-nixos/issues/13)
* **nix:** blockscout-nginx reverse-proxy module with ACME 🔐 ([#16](https://github.com/Klazomenai/autonity-blockscout-nixos/issues/16)) ([631fff4](https://github.com/Klazomenai/autonity-blockscout-nixos/commit/631fff48839b039e64967705e6fd7898fe2bbd78)), closes [#15](https://github.com/Klazomenai/autonity-blockscout-nixos/issues/15)
* **nix:** blockscout-postgresql wrapper module ⛵ ([#8](https://github.com/Klazomenai/autonity-blockscout-nixos/issues/8)) ([b3a6989](https://github.com/Klazomenai/autonity-blockscout-nixos/commit/b3a698929acd0f9fb0555f88c0dcecb21b43e6b4))
* **nix:** blockscout-redis wrapper module (unix socket) ⛵ ([#10](https://github.com/Klazomenai/autonity-blockscout-nixos/issues/10)) ([8b323a5](https://github.com/Klazomenai/autonity-blockscout-nixos/commit/8b323a514aebb4e2eea2a30400f7cd4ce16757fc))
* **nix:** chainId Nix variable threaded through test fixture (autonity + frontend) ⛵ ([#40](https://github.com/Klazomenai/autonity-blockscout-nixos/issues/40)) ([196b527](https://github.com/Klazomenai/autonity-blockscout-nixos/commit/196b5273a6539b4c1ef66d7d7c7a1e237ddd8479))
* **nix:** one-time eth_syncing empirical probe + M3 design note ([#44](https://github.com/Klazomenai/autonity-blockscout-nixos/issues/44)) ([1de9c19](https://github.com/Klazomenai/autonity-blockscout-nixos/commit/1de9c19fd4f7c61801c6e65dc92f7bff29b06a7a)), closes [#36](https://github.com/Klazomenai/autonity-blockscout-nixos/issues/36)
* **nix:** runtime readlink -f check on secret paths 🔐 ([#27](https://github.com/Klazomenai/autonity-blockscout-nixos/issues/27)) ([0a0d043](https://github.com/Klazomenai/autonity-blockscout-nixos/commit/0a0d0435dc2d8421d380f8677c8e29e8d8e9a274))
* **nix:** services.autonity.network = "dev" enum value ⛵ ([#39](https://github.com/Klazomenai/autonity-blockscout-nixos/issues/39)) ([637b3a4](https://github.com/Klazomenai/autonity-blockscout-nixos/commit/637b3a4c29ff1f2fae3d8059b3e7a6d849c59a56))
* **nix:** services.autonity.staticNodes option ⛵ ([#26](https://github.com/Klazomenai/autonity-blockscout-nixos/issues/26)) ([9434f86](https://github.com/Klazomenai/autonity-blockscout-nixos/commit/9434f868c1c4c452d42508a29d27b2b623a28cd6))


### Miscellaneous Chores

* gitignore tests/__pycache__ + Release-As override for v0.1.0-alpha.0 ⛵ ([#48](https://github.com/Klazomenai/autonity-blockscout-nixos/issues/48)) ([7a3b590](https://github.com/Klazomenai/autonity-blockscout-nixos/commit/7a3b5901ead68e0b77fc7f9951a1fae34096c0c1)), closes [#47](https://github.com/Klazomenai/autonity-blockscout-nixos/issues/47)

## Changelog

Managed by [release-please](https://github.com/googleapis/release-please). Entries are added automatically from Conventional Commit messages when release PRs are cut.
