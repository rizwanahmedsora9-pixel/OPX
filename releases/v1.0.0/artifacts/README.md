# v1.0.0 build artifact

The successful Actions run is [36314459902](https://github.com/rizwanahmedsora9-pixel/OPX/actions/runs/36314459902), for source commit `2fe745e70c7ee06bdcc593bf4833e070c023c19d`. Its artifact is named:

`rns-router-11-2fe745e70c7ee06bdcc593bf4833e070c023c19d`

The artifact download was attempted from this environment, but GitHub's artifact-storage endpoint returned `EOF` twice. Therefore the ISO is **not present in this folder** and must not be represented as archived here. Download the artifact from the Actions run above (while it remains retained), extract `rns-router.iso` into this folder, and create its checksum with:

```sh
sha256sum rns-router.iso > rns-router.iso.sha256
```

Then update `../README.md` with the checksum and confirm the image boots before calling this a complete archived release. Do not add a placeholder ISO or checksum.
