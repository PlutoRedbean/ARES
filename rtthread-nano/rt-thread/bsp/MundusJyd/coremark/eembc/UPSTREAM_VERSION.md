# Vendored EEMBC CoreMark

- Repository: `https://github.com/eembc/coremark.git`
- Branch: `main`
- Commit: `1f483d5b8316753a742cbf5590caf5bd0a4e4777`
- Commit date: `2025-05-01`

The files in this directory are copied byte-for-byte from that commit.  The
upstream `coremark.md5` validates all five benchmark C files.  At this commit
its recorded `coremark.h` MD5 is stale after upstream commit `4ee6eca` fixed a
header typo; the actual vendored header MD5 and all SHA-256 values are recorded
below so this snapshot remains reproducible.

Run `sha256sum -c SHA256SUMS` in this directory to verify the six benchmark
source/header files after any build.  The build system reads these files but
does not write to them.

```text
MD5
9007fe7861b60ee6f210d156b62974c8  core_list_join.c
4a9e6dadce1ac3866381021fbe843fc9  core_main.c
5fa21a0f7c3964167c9691db531ca652  core_matrix.c
fb49e7605c125306575a83f14f5798ac  core_state.c
45540ba2145adea1ec7ea2c72a1fbbcb  core_util.c
b0ec69b6c8e75853d06accb3b1bcf534  coremark.h

SHA-256
ca00e4e010ece47d7f040cb92aa50a95345a00d3171b59d088f6b243be06ce7b  core_list_join.c
17884c93c5b94378eb0ff02b4df3725756cf2addb9b8cbcaa6200a4649ff5ca7  core_main.c
ecdff717b5a5c4907d221a606760e25499899cbf617582c05d40db71c91351e4  core_matrix.c
f4b84bb0a3452c45a4daa664ab502bfdccbd31cb57d93e9ac490c60937717a4e  core_state.c
a3fbfcb9bb943b638624b8ece01c5836dd56a96d7bcde2697b248d077447327f  core_util.c
42642b9a06c7ed2b3bd9eda971b7c3868c4f5d27bf7ef6c4bba11291a0c2598a  coremark.h
```
