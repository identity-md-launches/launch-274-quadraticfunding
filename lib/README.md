Dependencies are vendored as ordinary source files; no network or submodules are needed to build.

- OpenZeppelin Contracts **v5.0.2**: the unmodified Solidity dependency closure for ERC20,
  SafeERC20, ReentrancyGuard and Math, plus LICENSE. Upstream:
  https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.0.2
- forge-std **v1.9.7**: unmodified `src/` and both license files. Upstream:
  https://github.com/foundry-rs/forge-std/tree/v1.9.7

Downloaded from the corresponding GitHub release-tag archives. Solidity is pinned separately
in foundry.toml and must be available to Foundry as a compiler; no compiler binary is vendored.
