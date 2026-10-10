# Preliminary prior-art search: object measurement from multi-frame depth

**What this is.** Notes from a few hours of web searching on 2026-10-10, for
handing to a patent agency. It is **not** a professional search and not a
legal opinion.

**Limits.**

- General web search only. No access to CNIPA's search system, Espacenet
  full text, or any commercial patent database.
- Most references were read as search-result summaries. Only two were opened
  (EP4024330A1 and the first part of US12122428B2), and neither was read to
  the end of its claims.
- Chinese-language coverage was poor: the queries returned mostly US and EP
  documents.
- Finding nothing here does not mean nothing exists.

Steps A–E refer to [`invention-disclosure-outline.md`](invention-disclosure-outline.md).

## Summary

| Step | Finding | Effect on a filing |
|---|---|---|
| A. Validated multi-frame voxel fusion | Known. | Context only. |
| B. Support plane removed for segmentation, coordinate kept for height | Removing a ground plane and measuring from a reference surface are both established in dimensioning. Nothing found on the one-sided noise estimate driving the band. | Not a main claim. The one-sided estimate could be a dependent claim. |
| C. Conditional connectivity | No dimensioning document found with this rule. But size-dependent merging is a textbook idea in segmentation, and a 2020 patent merges small segments preferentially after deliberate over-segmentation. | Weaker than the first pass suggested. Expect an inventive-step objection; the claim would have to recite the specific rule and its measured effect. |
| D. Evidence checks | Confidence feedback and refusing a low-confidence measurement are known in handheld dimensioners. Nothing found resembling the interior-partition test. | Dependent claims; the interior-partition test is the one to search properly. |
| E. Refuse or qualify | Known as a concept. | Not a claim by itself. |
| Free-space gating of bridging (new, experimental) | No document found that gates a merge on rays having passed through the gap. But free-space carving is standard, and the same 2020 patent names beams "passing through regions … without interacting" as unused information that could improve segmentation. | Promising only as a specific mechanism with device data. The idea alone is likely to be called an obvious combination. |

## Closest references

### Dimensioning from depth data

| Reference | What the summary or text shows | Bears on |
|---|---|---|
| [US10262222B2](https://patents.google.com/patent/US10262222), method and system for measuring dimensions of a target object | Depth data to point cloud; planes extracted; ground plane identified and removed; remaining points clustered; nearest cluster taken as target; handheld device. | A, B, C (baseline pipeline) |
| [US11361461](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/11361461), electronic device and object measurement method | Removes points at and below a reference surface; reference surface chosen as the height with the most points. | B (histogram-style support detection) |
| [CN108332662A](https://patents.google.com/patent/CN108332662A/zh), object measurement method and device | Parcel volume from colour plus depth; a reference depth is used with the computed object height. | B |
| [US12423846B2](https://patents.google.com/patent/US12423846), reference surface detection for mobile dimensioning (Zebra) | Detecting the floor reference plane on a mobile dimensioner. | B |
| [US10964043](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/10964043), measuring dimension or volume by eliminating redundant voxels | Several depth maps taken at different times, combined in voxels. | A |
| [US10096131](https://patents.google.com/patent/US10096131) / [US10769806](https://patents.google.com/patent/US10769806), dimensional acquisition of packages | Depth maps filtered, transformed, point cloud on a dimensioning surface, edge lengths and height. | A, B |
| [US11087481](https://patents.google.com/patent/US11087481), box dimension from a depth map | Plane fitting of box faces. | Alternative approach |
| [US10218964B2](https://patents.google.com/patent/US10218964) family, dimensioning system with feedback (Honeywell/Hand Held) | Confidence from the share of valid depth pixels; error feedback below a threshold. | D, E |
| [US11480425B2](https://patents.google.com/patent/US11480425) / [US11776153B2](https://patents.google.com/patent/US11776153), mobile dimensioning (Zebra) | Low-confidence measurements may trigger a warning or be discarded. | E |

### Segmentation: merging, splitting, and free space

| Reference | What the summary or text shows | Bears on |
|---|---|---|
| [US12122428B2](https://patents.google.com/patent/US12122428B2/en), camera-LiDAR object detection with segment merging (Argo AI / Ford, priority 2020-10-23) | Deliberately over-segments, then merges. The merge test includes a bias that favours merging small segments. Criticises earlier methods for not using "the negative information provided by LiDAR returns passing through regions of the environment without interacting". In the part read, its own merging uses learned features, not free space. Claims not read. | C and free-space gating: the nearest thing found to both ideas. Read in full. |
| [US11662469B2](https://patents.google.com/patent/US11662469), system and method for merging clusters (Denso) | Two-phase merge of LiDAR clusters: distance first, then motion similarity. | C (two-stage merging) |
| [EP4024330A1](https://data.epo.org/publication-server/rest/v1.2/patents/EP4024330NWA1/document.html), object recognition method (Nissan/Renault, filed 2019-08-28) | Groups points, fits a polygon, then uses sight lines from the sensor to decide whether the group is one object or several: points seen only on sides the sensor could not have seen mean the polygon is a recess between objects. Vehicle LiDAR, top view; no measurement. | Free-space gating, D (single-versus-plural test from line of sight) |
| [arXiv 2109.08224](https://arxiv.org/pdf/2109.08224), divide-and-merge clustering for LiDAR panoptic segmentation | States the trade-off a single distance threshold forces between splitting one object and joining two; clusters locally, then decides merges. | C (the problem statement is published) |
| Felzenszwalb and Huttenlocher, *Efficient Graph-Based Image Segmentation*, IJCV 2004 | Not from this search: recalled from the literature. Its merge threshold shrinks as a component grows, so small components merge readily and large ones resist. | C: an examiner may treat conditional connectivity as a hard-threshold form of this. Confirm against the paper. |
| Free-space carving in volumetric fusion (TSDF fusion, occupancy mapping) | Standard technique; the search surfaced reconstruction papers that label space by the rays passing through it. | Free-space gating (the evidence itself is not new) |
| [Cognex side-by-side detection](https://www.cognex.com/videos/vision-systems/side-by-side-detection---sortation-logistics) | Commercial 3D system marketed as detecting two parcels side by side. Product material, not a patent; method not stated. | D (merged-object detection exists commercially) |

## What changed since the first pass

- **Step C is less distinctive than it looked.** The first pass found no
  direct hit in dimensioning. This pass found the general principle
  (small pieces merge more readily than large ones) in a 2004 paper and a
  2020 patent. What remains specific to this pipeline is the exact rule:
  a component that reaches object size under strict connectivity is frozen
  in both directions, wider connectivity applies only among the rest, the
  result is chosen by distance to a seed, and its use is recorded.
- **Free-space gating has a published pointer toward it.** US12122428B2
  says through-passing beams are unused information for segmentation. A
  claim would need to be the particular mechanism (per-voxel counts of frames
  seen through, compared with frames seen occupied, tested along the line
  between two fragments, in a hand-held measurement), supported by device
  results.

## Questions for a professional search

1. Read US12122428B2 and its family in full. Does any claim or embodiment
   use through-passing beams to decide a merge?
2. Search for conditional or size-gated connectivity in **dimensioning**
   and **parcel volume measurement**, in Chinese and English.
3. Search for free-space or visibility tests used to decide whether two
   point-cloud segments are one object.
4. Search for detecting two merged objects from an internal dense sheet of
   points (the interior-partition test).
5. Search for a support-plane noise estimate taken from one side of the
   plane only.

Suggested classes: G01B 11/00, G01B 11/02, G06T 7/11, G06T 7/187, G06T 7/62,
G06T 2207/10028, G06V 20/64, G01S 17/89.

Suggested terms, to be combined with 体积测量 / 尺寸测量 / dimensioning:

- 连通域, 欧式聚类, 双阈值, 小簇合并, 条件合并, 碎片合并
- 自由空间, 射线投射, 可见性, 占据栅格, 光线穿过, 间隙, 空洞
- 支撑面, 基准面, 噪声带, 单侧
- 粘连, 并排, 多包裹, 内部隔面
- conditional connectivity, size-gated merge, over-segmentation and merge,
  free-space carving, see-through, visibility constraint, cannot-link
