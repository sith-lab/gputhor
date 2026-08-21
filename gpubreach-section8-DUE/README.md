# GPUBreach (IEEE Symposium on Security & Privacy, 2026)

## Modifications From Original GPUBreach

1. `s2_firstRegion.*`: Incorporate cuMemMap in order to predict corrupted PTE location
2. `s3_firstRegion_hammer.*`: Leverage the prediction to obtain arbitrary R/W in 10ms window, escalating privilege given IOMMU is disabled.
3. Removed unecessary `app_*` files and those required for privilege escalation when IOMMU is enabled.
4. Included GPUThor kernels.