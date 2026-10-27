# CoreMark image for the ARES L2 testbenches

Vendored EEMBC CoreMark 1.0 sources plus the ARES AbstractMachine port.  The
benchmark core is unmodified; see `NOTICE.md` for hashes, frozen parameters
and the trademark boundary, and `LICENSE.md` for the license.

Normal use is through the repository-level target, which stamps the image and
the input hashes into `build/coremark/inputs.json`:

    make coremark-image          # build ELF -> bin -> 128-bit readmemh + inputs.json
    make test-coremark-image     # converter negative/positive tests (no RTL)

Then the long-program regressions pick the generated image up automatically:

    make unit-coremark
    make unit-2core-coremark
    make unit-2core-coremark COREMARK_ARGS=+H1EN=0   # single-hart reference mode

Passing `DMEM=<path>` still overrides the generated image.  Long programs are
deliberately not part of `make all`.
