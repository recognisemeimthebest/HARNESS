# T1: 3D Lung Tumor Segmentation - Experiment Report

> **Date**: 2026-04-16  
> **Task**: NSCLC CT 3D tumor segmentation  
> **GPU**: NVIDIA GeForce RTX 3060 12GB  
> **Framework**: MONAI + PyTorch 2.11

---

## 1. Experiment Setup

| Item | Detail |
|------|--------|
| **Train** | LUNG1 (NSCLC-Radiomics) 421 patients |
| **Validation** | Radiogenomics 28 patients |
| **Test** | Radiogenomics 28 patients (external) |
| **Patch Size** | 96 x 96 x 96 |
| **Loss** | DiceCE Loss |
| **Optimizer** | AdamW (lr=1e-4, weight_decay=1e-5) |
| **Scheduler** | CosineAnnealingLR (T_max=300) |
| **EarlyStopping** | patience=5, check every 5 epochs |
| **Dropout** | 0.2 (all models) |
| **Max Epochs** | 300 |
| **Validation** | Tumor-centered crop (fast) |
| **Test** | Sliding window inference (overlap=0.5) |

---

## 2. Results Summary (Val Dice ranking)

| Rank | Model | Paper | Params | Batch | Best Val Dice | Best Epoch | Test Mean | Test Max | Test >=0.5 | Time |
|:---:|-------|-------|------:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| 1 | **SegResNet** | Myronenko 2018 | 18.8M | 2 | **0.5969** | 115 | - | - | - | 306 min |
| 2 | **MedNeXt** | Roy et al. 2023 MICCAI | 5.6M | 1 | **0.5794*** | 50+ | - | - | - | training |
| 3 | BasicUNet | Ronneberger et al. 2015 | 5.7M | 2 | 0.5500 | 45 | 0.2399 | 0.9099 | 7/28 | 108 min |
| 4 | VNet | Milletari et al. 2016 | 45.6M | 2 | 0.5286 | 95 | **0.3808** | **0.9110** | **11/28** | 457 min |
| 5 | AttentionUnet | Oktay et al. 2018 | 5.9M | 2 | 0.5092 | 85 | 0.1752 | 0.8602 | 3/28 | 175 min |
| 6 | DynUNet | Isensee et al. 2021 | 16.5M | 2 | 0.4894 | 60 | - | - | - | 118 min |
| 7 | HighResNet | Li et al. 2017 | 0.8M | 2 | 0.0000 | - | 0.0000 | 0.0000 | 0/28 | 26 min |
| - | BasicUNetPlusPlus | Zhou et al. 2019 | 7.0M | 1 | - | - | - | - | - | error |

> \* MedNeXt still training (epoch 55, val 0.5794 at ep50)  
> `-` = killed early or not yet tested  
> SegResNet, DynUNet: killed early before test phase, checkpoints preserved  
> HighResNet: OOM during training, failed to learn  
> BasicUNetPlusPlus: list output bug (UNet++ deep supervision), pending fix rerun

**Remaining**: SwinUNETR, UNETR (queued after MedNeXt)

---

## 3. Key Findings

### Val vs Test Gap
- Validation uses tumor-centered crop (96x96x96), test uses full-volume sliding window
- Large val-test gap observed: BasicUNet val 0.55 -> test 0.24
- Patients with no/small tumors get Dice=0 on test, dragging down the mean

### Test Performance (completed models only)
- **VNet** surprisingly best on test (mean 0.38, 11/28 >= 0.5) despite lower val score
- VNet's large capacity (45.6M params) may help generalize with sliding window inference
- R01-089 consistently best patient across models (BasicUNet 0.91, VNet 0.91)

### Per-Patient Test Dice (BasicUNet)
| Patient | Dice | Patient | Dice |
|---------|:---:|---------|:---:|
| R01-089 | 0.910 | R01-144 | 0.684 |
| R01-103 | 0.654 | R01-139 | 0.625 |
| R01-121 | 0.615 | R01-142 | 0.551 |
| R01-102 | 0.468 | R01-078 | 0.345 |
| R01-133 | 0.295 | R01-023 | 0.287 |
| 11 patients | 0.000 | - | - |

### Per-Patient Test Dice (VNet, best test model)
| Patient | Dice | Patient | Dice |
|---------|:---:|---------|:---:|
| R01-089 | 0.911 | R01-121 | 0.848 |
| R01-102 | 0.754 | R01-103 | 0.740 |
| R01-139 | 0.682 | R01-122 | 0.650 |
| R01-142 | 0.610 | R01-116 | 0.607 |
| R01-023 | 0.573 | R01-133 | 0.566 |
| R01-142 | 0.551 | R01-135 | 0.498 |

### Model Efficiency
| Model | Params | Val Dice | Dice/M params |
|-------|------:|:---:|:---:|
| MedNeXt | 5.6M | 0.5794 | 0.104 |
| BasicUNet | 5.7M | 0.5500 | 0.096 |
| AttentionUnet | 5.9M | 0.5092 | 0.086 |
| SegResNet | 18.8M | 0.5969 | 0.032 |
| VNet | 45.6M | 0.5286 | 0.012 |

---

## 4. Training Curves (Val Dice)

```
Val Dice
0.60 |                                          * SegResNet (0.5969)
     |                                    *  MedNeXt (0.5794, training)
0.55 |                              *          * BasicUNet (0.5500)
     |                        *          
0.50 |                  *               *      * VNet (0.5286)
     |            *                      *     * AttentionUnet (0.5092)
0.45 |      *                                  * DynUNet (0.4894)
     |  *
0.40 |
     +----+----+----+----+----+----+----+----+---> Epoch
     0   15   30   45   60   75   90  105  120
```

---

## 5. Next Steps

1. **MedNeXt**: Wait for completion + test evaluation
2. **SwinUNETR / UNETR**: Transformer-based models queued
3. **BasicUNetPlusPlus**: Rerun with fixed list output handling
4. **SegResNet test**: Run test on saved checkpoint (`SegResNet_best.pt`)
5. **Target**: Dice >= 0.7 (not yet achieved, may need additional models or tuning)

---

## 6. Environment

- **GPU Server**: 192.168.0.16 (RTX 3060 12GB, 32GB RAM)
- **Conda Env**: livertumor (PyTorch 2.11 + CUDA 12.8)
- **Data**: `/home/team4/LJW/LiverTumor/cache_lung1/`, `cache_radiogenomics/`
- **Checkpoints**: `/home/team4/LJW/LiverTumor/checkpoints_t1/`
- **Results JSON**: `/home/team4/LJW/LiverTumor/results/t1_experiment_log.json`
