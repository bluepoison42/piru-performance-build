# Piru 1.6 技术审计报告

审计对象：bluepoison42/piru-performance-build 的 perf-1.6 分支  
冻结提交：bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d  
审计日期：2026 年 10 月 31 日  
用途：供维护者安排修复与回归验证，不作为已通过真机验收的证明

## 结论与修复顺序

本轮列入主报告 12 项问题，集中在剂量数值、组合成分身份、库存单位、删除与备份生命周期，时段状态和 Android 导出通知，以及全历史 Timeline 的平方级扫描。另有 7 项旧问题或已知保护边界仍需处理；它们单独列出，不重复包装成新发现。主报告的 12 项中，8 项在 main 的旧版本已存在，3 项继承自移植前的 1.6 发布树，只有 N09 的这条新依赖交互来自 perf 改动。多数是继承缺陷，“本轮首次确认”不等于“本轮移植新增”。

应先处理会保存错误数值、删除错误记录或覆盖恢复副本的路径，再修复状态展示和通知、导出生命周期。当前构建流程可以在未运行回归测试的情况下产出成功 APK；已经成功的构建与本次冻结提交也不是同一个 SHA，因此不能据此把目标版本标成已验收。

本报告以完整源码调用链和反例检查为主，辅以独立 Python 算法模型，以及一次实际标准 SQLite 的 WAL 复制竞态实验。本次没有运行 Swift 测试、Android 应用、模拟器或真机，算法复现不等于应用端测试通过。本文用例均为人工测试数据，不涉及个人用药记录，也不是剂量建议。

### 主要问题一览

| 编号 | 优先级 | 问题与实际影响 | 适用范围 |
|---|---|---|---|
| N01 | P1 | 按体积输入将实际保存量统一舍入至 0.1 单位；小量可变成 0 并禁止保存 | 共享 QuickLog 剂量编辑 |
| N02 | P1 | 液体组合调整总体积只缩放部分成分，其他成分仍保存原量 | 含不兼容体积元数据的组合 |
| N03 | P2 | 组合成分丢弃品牌 释放形式和异构体身份 | 选择带身份细分的搜索结果 |
| N04 | P1 | 原生库存合并把 g 等原始数值直接计入 mg 等目标单位 | 同身份库存跨单位合并 |
| N05 | P1 | Delete Everything 后 Android 文件夹备份仍启用，随后覆盖保留副本 | 已配置文件夹自动备份 |
| N06 | P2 | 备份前保存失败被吞掉，仍可能以旧已提交数据报告备份成功 | Android 文件夹备份 |
| N07 | P1 | 具体时间行的撤销按钮删除该药当日最新记录，而非所点时段记录 | 同药同日多时段 |
| N08 | P2 | QuickLog 按记录数量推断已服时段，与实际最近时段匹配相矛盾 | 漏服早段而已记录晚段 |
| N09 | P2 | 提醒时间改动但数量不变时，streak 缓存仍返回旧结果 | 含历史 skip 的日程编辑 |
| N10 | P2 | 重复提醒已显示后从 delivered 索引消失，删除数据不能可靠清除通知 | Android 重复提醒 |
| N11 | P2 | 系统保存界面期间进程重建丢失导出源，把已选目标当作取消 | Android SAF 导出 |
| N12 | P2 | 全历史 Timeline 在主线程含平方级扫描，历史增长时工作量非线性增长 | 全历史时间线重建 |

P1 表示应在继续把该版本用于重要记录前优先修复的直接数据正确性或恢复风险；P2 表示明确的状态、生命周期或验证缺口。优先级不表示这些问题已在用户设备发生。Android 专属路径只按 Android 结论报告；共享 Swift 路径已核对移植排除、补丁与替换规则未改写相关算法。

### 建议执行顺序

1. **先封住错误写入和备份覆盖。** 修复 N01、N02、N04、N05、N07；同时修复旧问题 K01 与 K03 的持久化来源和成功条件。先加失败断言，再改实现。
2. **统一日程和编辑状态。** 用 occurrence 的稳定身份驱动 Due、skip、撤销和提醒；处理 N03、N08、N09，以及旧问题 K05、K06。不要用减去 skip 总数继续推算下标的局部补丁。
3. **补上 Android 生命周期。** 修复 N06、N10、N11；用系统通知和实际文档提供方做回归，而不是只验证纯模型。
4. **消除全历史重复扫描，并把构建和证据绑定到同一 SHA。** 对 N12 先用操作次数验证线性增长，再做设备测量。 恢复回归门禁，固定实际 Gradle，核对完整依赖图；随后对修复提交运行宿主测试和设备验证，保存 APK 哈希及测试结果。

### 问题来源不是只和 main 比较

当前 main 基线 [c0b91e0](https://github.com/bluepoison42/piru-performance-build/commit/c0b91e0778bdac494903d9af3f9a91b43a57ff45) 是 Release v1.5，而非 1.6。另核对了移植前发布树 [6f9ec37](https://github.com/bluepoison42/piru-performance-build/commit/6f9ec37bdf8a3f0d38ee8f60130fd3ce49f56f27)，它是 Release v1.6，也是首个 performance port 提交 f620dd2 的直接父提交。只看“与 main 有差异”会把上游 1.6 功能误算成移植新增。

| 来源分类 | 编号 | 核实结论 |
|---|---|---|
| main 旧版本已有的共享逻辑 | N04 N07 N08 N12 | 库存合并 时段撤销 Due 推断和 Timeline 扫描已经存在 |
| main 旧版本已有的 Android 集成 | N05 N06 N10 N11 | 文件夹备份 通知 bookkeeping 和 SAF 生命周期缺口已经存在 |
| 移植前 1.6 发布树已有 | N01 N02 N03 | 旧舍入遇上通用溶液扩展 液体组合缩放和成分身份丢失由发布树继承 |
| perf 新交互 | N09 | skip-aware adherence 加入精确时间依赖，旧 count-only 缓存键未同步扩展 |

N01 的舍入本身在 main 已存在；新通用单位的暴露来自 1.6 发布树。N09 的旧键不是新写的，但 f620dd2 新增的精确 skipped-slot 计算让该键不再充分。这是代码树来源判断，不是对具体开发者责任的推断。旧问题 K01 至 K07 的“旧”表示此前审计已经记录，不表示它们都与 main 旧树相同。

## 审计范围与证据标准

冻结源码包含 3296 个受版本控制的文件，其中 1080 个 Swift 文件和 56 个补丁文件。重点不是逐个文件平均检查，而是沿可造成错误保存、恢复失败、日程失真和移植行为差异的实际入口追踪。核查了共享 SwiftUI 业务代码、PortableData 持久化、原生导入导出、Android 文件夹备份和 SAF、日程与提醒、组合及按体积功能、CI 和依赖 staging。

Android 不是原封不动执行共享源文件：stage.py 先复制，再应用排除规则、补丁、正则替换及模板桥接。本报告对主要发现核对了这条有效源码路径，未把宿主替身或有意为空的平台 stub 当作产品实现。没有修改源仓库或远端，没有创建 Work，没有发布报告到仓库。

| 证据级别 | 本次实际完成 | 能支持的结论 |
|---|---|---|
| 源码闭环 | 从 UI 或生命周期入口追到状态转换 持久化及后续读取；检查反例和现有测试 | 确认分支缺陷及其触发条件 |
| 独立算法模型 | Python 重写最小算术及状态流程并执行 | 校验数值和时序推理，不替代生产测试 |
| 实际 SQLite 实验 | 在临时测试库执行 main 与 WAL 分步复制及 checkpoint 交错 | 证明旧快照竞态能生成可读但过时的副本 |
| 项目测试审阅 | 阅读现有 Swift 测试与回归草稿 | 判断覆盖空白，不能声称通过 |
| CI 历史核对 | 比对已记录运行的 SHA job 结论和产物路径 | 说明那些提交的构建结果及当前门禁限制 |
| 未完成项 | Swift 编译测试 Android 启动 通知 SAF Compose 真机故障注入 | 仍需修复后工程验证 |

旧报告基线为 piru-audit 仓库提交 8605b11ce6287335089a98523438a9b6c4fb20a9。旧报告实际审计源码与当前目标不同；旧编号只用于识别重复发现，不直接移用旧行号。当前所有源码链接固定到 bad4aa1，不随分支继续变动。

## 主要问题

### N01 按体积输入改变实际保存量

来源：main 已有舍入；通用溶液触发面继承自移植前 1.6。

**优先级 P1。** 这不是单纯显示精度问题。编辑模型把体积乘浓度的结果舍入至所选单位的十分之一，并把结果写入 staged components；QuickLog 随后直接保存 totalAmount。新通用 solution 支持 µg、mg、g、IU 等用户单位，却没有先转换为统一的高精度基准。

**定位与证据。** [StagedDoseEditorModel.swift 251 至 257 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Views/QuickLog/StagedDoseEditorModel.swift#L251-L257)；[ByVolumeDosing.swift 205 至 222 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Shared/ByVolumeDosing.swift#L205-L222)；[QuickLogView.swift 577 至 602 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Views/QuickLog/QuickLogView.swift#L577-L602)。

**最小触发。** 同一人工测试溶液只改表达单位，就会得到不同的实际保存量。

| 体积 | 浓度输入 | 数学结果 | 当前保存分支 |
|---|---|---|---|
| 0.25 mL | 1 g 每 mL | 0.25 g 即 250 mg | 0.3 g 即 300 mg |
| 0.25 mL | 1000 mg 每 mL | 250 mg | 250 mg |
| 0.04 mL | 1 单位每 mL | 0.04 单位 | 变为 0 保存被禁用 |

零值由托盘正数检查阻止提交，不应描述成已保存零剂量。原体积与浓度仍保留，因此元数据和保存量还可能相互矛盾。

**补充边界。** QuickLog 重开或切换模式经过一位小数格式化，还可能把 0.26 mL 自动填回为 0.3 mL，或把 0.04 mL 填回为 0.0 mL。用户主动清空或填无效浓度时，syncCustomDrink 提前返回而旧正数仍在托盘，保存有效性没有随编辑字段变为无效。该问题合并在本项，不另凑一个主发现。普通 Journal 的通用溶液编辑并不会自动走相同的重舍入路径。

**修复。** 数值模型保留经过有限值和范围校验的原始计算精度，格式化只用于显示；采用单位相关的显示精度。把当前编辑模式的有效性传递到提交条件，区别初次打开和主动改成无效输入。

**回归。** 覆盖 0.25、0.04、0.125 以及正常整数结果；不同单位；重开和切换模式后数值不变；清空浓度后不可保存旧量。断言真实 editor → tray → commit 路径，而不只测试 mass() 数学函数。独立算法复现确认了舍入结果。

### N02 液体组合总体积只更新部分成分

来源：移植前 1.6 的液体组合算法已存在，非 Android 专属。

**优先级 P1。** 初次加入托盘时所有成分按总体积计算正确；之后修改共同体积，只更新被标成 liquid combination row 的成分。Alcohol 的百分比体积能力，以及自身体积能力与成分单位不一致的情况，会被排除在该标记之外。

**定位与证据。** [DoseTray.swift 845 至 897 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Views/QuickLog/DoseTray.swift#L845-L897)；[同文件 982 至 985 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Views/QuickLog/DoseTray.swift#L982-L985)；[StagedProductEditor.swift 116 至 145 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Views/QuickLog/StagedProductEditor.swift#L116-L145)。

**最小触发。** 人工液体组合含测试成分 A 每 mL 1 mg，以及 Alcohol 每 mL 0.1 g。加入 1 mL 后分别为 1 mg 和 0.1 g；将总体积改成 5 mL，A 变成 5 mg，Alcohol 仍为 0.1 g，而不是 0.5 g。组件量在共同编辑器里只读，提交也不从产品定义重新计算，因此可保存混合比例错误的记录。

**反例核查。** 产品表单没有阻止上述成分和单位；Android 移植规则未修补这个计算。没有独立体积能力的普通成分，以及单位恰好兼容的成分正常更新，所以不能写成所有液体组合都错误。

**修复。** 把组合的总体积和每成分浓度作为独立产品元数据，不借用单物质的 volumeML/abv 字段。每次总体积变化重新计算全部成分；不能简单移除原有 capability guard，否则会把 Alcohol 的 ABV 错当通用浓度。若短期无法支持，应明确拒绝不兼容组合。

**回归。** 上述混合能力组合从 1 mL 调到 5 mL 后逐成分断言；改变成分顺序；同能力非基准单位；保存后再读出；正常全兼容组合做对照。已由独立算法模型及源码交叉复核。

### N03 组合成分丢失品牌和身份细分

来源：移植前 1.6 产品选择器与模型已存在。

**优先级 P2。** 成分选择器允许用户选中带品牌、异构体或释放形式的匹配结果，但保存时只保留 canonical substance、量、单位和途径。显示标签并未进入 CombinationComponent；之后 staging 用通用物质名解析默认身份。

**定位与证据。** [MedProductForm.swift 24 至 33 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Views/Journal/DailyDose/MedProductForm.swift#L24-L33)；[同文件 132 至 137 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Views/Journal/DailyDose/MedProductForm.swift#L132-L137)；[同文件 319 至 327 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Views/Journal/DailyDose/MedProductForm.swift#L319-L327)；[DoseTray.swift 820 至 834 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Views/QuickLog/DoseTray.swift#L820-L834)。

**最小触发。** 给组合添加搜索得到的 Concerta，保存并重新打开，再加入托盘。保存的是 Methylphenidate，缺少所选品牌和 XR 细分。现有 [PSIDResolutionTests.swift 68 至 85 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/PiruTests/PSIDResolutionTests.swift#L68-L85) 明确验证了这类身份差别，因此不只是丢一个装饰名称。异构体别名也有同类路径。

**影响边界。** 只适用于确实携带这些身份的搜索结果，不代表所有品牌都会改变曲线或效力。普通单物质 staging 保留品牌，不属于本项。combinationName 是用户组合名称，不能恢复已丢掉的成分身份。

**修复与回归。** 给成分模型添加向后兼容的可选身份字段，并贯穿保存、导入、staging 和 commit；或先把选择器限制为不带细分的 canonical 成分并明确提示。增加品牌、XR、异构体的保存重开及日志往返测试，并以通用成分为对照。

### N04 原生库存合并直接混用不同单位

来源：main 旧版本的共享导入逻辑已存在。

**优先级 P1。** 库存项目按物质身份加 salt 查找已有项，不按单位区分。导入已有项时直接合并事件原始数值并保留目标项单位，没有转换或拒绝。事件自己不带单位，合并后也无法补救。

**定位与证据。** [DataExportImport+PiruNative.swift 629 至 650 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Utilities/DataExportImport+PiruNative.swift#L629-L650)；[InventoryService.swift 245 至 247 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Data/Services/InventoryService.swift#L245-L247)；[InventoryItem.swift 18 至 21 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Shared/Models/InventoryItem.swift#L18-L21)。

**最小触发。** 本地同物质库存单位是 mg；导入另一个来源的 1 g 补货事件，UUID 尚未出现。它被记作 1 mg 而非 1000 mg。反向可放大导入贡献 1000 倍；有其他库存时不能说总库存必然错 1000 倍。threshold、baseline、dose size 等可选标量也原样复制。

**反例核查。** 重导相同事件 UUID 会去重；空库恢复走新行分支并保留源单位，均不是错误触发。mergeDuplicateItems 的确会转换，但这里导入器已经把两项折成一项，它没有第二项可修复。现有 InventoryExportTests 覆盖同单位事件合并，没有跨单位断言。

**修复。** 在事件 UUID 合并前把事件和所有带单位标量转换到目标单位。按片数等计数单位需要同时检查源目标强度；不能安全换算时保留分开的数据或明确拒绝。

**回归。** g→mg、mg→g；阈值及基线换算；第二次重导幂等；相同片数单位但不同或未知强度；单文件内同身份不同单位两行。独立审阅和数值模型均确认。

### N05 删除全部数据后仍会覆盖保留的文件夹备份

来源：main 旧版本的 Android 文件夹备份集成已存在。

**优先级 P1。** Delete Everything 保留外部导出文件本身是正确行为，UI 也作了这一承诺。问题是 Android 文件夹自动备份没有被停用；删除后下次满足备份条件的后台事件会用清空后的库替换原副本。

**定位与证据。** [DataStorageModel.swift 229 至 235 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Views/Settings/DataStorageModel.swift#L229-L235) 调用的是 iCloud 备份停用；[BackupManager.swift 232 至 241 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Data/Backup/BackupManager.swift#L232-L241)；Android 实际管理器为 [FolderBackup+Android.swift 87 至 95 行及 108 至 140 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/android/app/Sources/Piru/Android/Backup/FolderBackup+Android.swift#L87-L140)。

**最小触发。** 先启用并成功写入文件夹备份，执行 Delete Everything，随后在满足最小间隔时后台化应用。文件夹 URI、口令和启用状态仍在；清空后的内容 revision 不同，正常发布替换固定文件名并清理 partial。供应方可能另有历史版本，但应用自身没有保留旧代际的保证。

**反例核查。** Android 的文件夹补丁只替换后台触发和设置界面，没有替换删除入口。内容 revision 门禁会挡相同内容，却挡不住一次真实清空。这里不是建议删除外部备份，而是要求停止后续覆盖它。

**修复与回归。** 删除前按平台停用自动备份，失效化正在进行的加密或发布任务，同时保留外部文件。测试正常删除后后台化、删除时已有备份任务、发布前后交错；断言旧备份字节和 revision 不变。单靠发布完成后的 cancellation 检查太晚。

### N06 备份前保存失败仍可能报告成功

来源：main 旧版本的 Android 备份错误处理已存在。

**优先级 P2。** Android 文件夹备份捕获 context.save() 错误后只记日志并继续。随后快照从新 context 读取已提交数据，不包含刚才未能保存的修改。当这版已提交内容尚未写到目标时，流程仍可报告 success。

**定位与证据。** [FolderBackup+Android.swift 114 至 140 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/android/app/Sources/Piru/Android/Backup/FolderBackup+Android.swift#L114-L140)；[BackupSnapshot.swift 54 至 72 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Data/Backup/BackupSnapshot.swift#L54-L72)。

**触发与结果。** 有未提交编辑，保存因磁盘满、数据库拒绝或编码错误失败。新建备份或尚未备份的已提交 revision 可继续发布，用户误以为刚改的内容也被保全。若 revision 已备份，则可能显示 idle 而非失败；不能说每次保存失败都会覆盖旧备份。

**修复与回归。** 把保存成功作为捕获前置条件，失败后保留 pending changes、报告失败并立即返回，不更新 revision。现有失败重试测试针对写文件失败，不覆盖捕获前保存失败；新增实际 run 入口故障注入，断言零捕获、零发布、旧副本不变。

### N07 具体时段的撤销按钮删除当日最新记录

来源：main 旧版本已有逐时段按钮与最近记录撤销的矛盾。

**优先级 P1。** UI 为每个具体时间展示自己的 taken 状态和勾选按钮，但 unlog(slot) 忽略所选时段和关联的 satisfyingEntryID，按当天同药最新 timestamp 删除。函数注释本来就写了“最近一次”；缺陷是逐时段 UI 与这个实现语义不一致，不是实现违背了注释。

**定位与证据。** [MyMedsCard.swift 223 至 235 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Views/Journal/DailyDose/MyMedsCard.swift#L223-L235)；[同文件 340 至 354 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Views/Journal/DailyDose/MyMedsCard.swift#L340-L354)；[MyMedsModel.swift 23 至 50 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Views/Journal/DailyDose/MyMedsModel.swift#L23-L50)。

**最小触发。** 同药 08:00 和 18:00 各有一条独立记录 A、B。19:00 点击 08:00 行已服勾选。代码删 B 而不是 A；之后按 occurrence 重算，早段仍 taken、晚段变 pending。当天还有更晚的非计划记录时，也可能删到它。

**修复与回归。** MedSlot 携带对应 occurrence 的日期、稳定 ID 和 satisfyingEntryID；点击时重新校验并只删该条，再 reconcile 和更新提醒。若关联已过期，应刷新而非退回“删最近一条”。回归必须断言删的是 A 的 UUID、B 及更晚独立记录仍在。主 context 有 autosave，因此本报告不把缺少显式 save 另列为“删除不会持久化”。

### N08 QuickLog 数量推断与最近时段匹配冲突

来源：main 旧版本已有 count-first 与 nearest-slot 两套逻辑。

**优先级 P2。** occurrence 按记录距离匹配最近未占用时段；QuickLog 则把记录条数当作已完成前 N 个时段。两套状态推导会对同一日给出互相矛盾的 Due。

**定位与证据。** [RoutineOccurrenceService.swift 261 至 277 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Data/Services/RoutineOccurrenceService.swift#L261-L277)；[QuickLogModels.swift 284 至 302 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Views/QuickLog/QuickLogModels.swift#L284-L302)。

**最小触发。** 有 08:00、18:00 两槽，只在 18:00 记一条。occurrence 正确标 18:00 logged、08:00 pending；QuickLog 因 takenCount 为 1，选择 times[1]，仍把 18:00 显示为 due。这与旧 skip 问题根因相邻，但本例不需要 skip。

**修复与回归。** QuickLog、My Meds、dock、提醒读取统一的当前日 occurrence 状态，别用数量猜位置。覆盖漏早服晚、早跳晚服、偏离计划的日志、04:00 前用药日边界。整组 pill 允许再次 staging 是代码中明确的快捷方式，不作为本项缺陷；这里确认的是 Due 标签误导。

### N09 同数量提醒时间编辑不使 streak 缓存失效

来源：f620dd2 新增 skip 精确时间依赖，未扩展旧缓存键。

**优先级 P2。** 缓存 signature 只放 reminderTimesMinutes.count，没有放实际时间；而 streak 计算会用精确 slotMinutes 判断历史 skipped 是否免计。时间数量不变时，同一输入键可以对应不同正确结果。

**定位与证据。** [AdherenceStreakStore.swift 43 至 76 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Utilities/AdherenceStreakStore.swift#L43-L76)；[AdherenceCalculator.swift 355 至 366 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Utilities/AdherenceCalculator.swift#L355-L366)。

**最小触发。** 前天 logged、昨天 08:00 skipped、今天尚未记录，先取得 streak 1；把唯一提醒由 08:00 改成 09:00。时间数量、剂量 revision 和日界均不变，缓存仍返回 1；按当前计算规则重新扫描时，昨天 09:00 无记录、无对应 skip，结果为 0。即使产品选择允许当前日程影响历史，这个缓存与 fresh scan 的不一致仍成立。

**修复与回归。** signature 纳入排序后的完整时间值和所有实际依赖，并确保 schedule 编辑触发消费者。增加同数量改时间且存在历史 skip 的测试，比较缓存调用与强制新扫描；无需把“历史日程不可变”的更大设计变更作为唯一修法。

### N10 重复提醒丢失已投递状态

来源：main 旧版本相同 vendor 补丁与基线枚举的组合已存在。

**优先级 P2。** Android vendor 补丁把下一次重复提醒沿用同一 identifier 并写回同一 date。已显示的通知还在系统托盘，但 delivered 查询只认 date≤now，于是找不到它。Delete Everything 先删 pending 再删 delivered，还会先移掉共享索引，导致已显示内容未被取消。

**定位与证据。** [0017 通知补丁 318 至 334 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/android/vendor/skip-ui/0017-notifications-recur-and-never-block.patch#L318-L334)；[同补丁 623 至 660 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/android/vendor/skip-ui/0017-notifications-recur-and-never-block.patch#L623-L660)；[DataStorageModel.swift 230 至 232 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Views/Settings/DataStorageModel.swift#L230-L232)。审阅使用与补丁 old-file hash 匹配的 skip-ui 1.64.0 基线并在审计副本应用补丁，未把未经核对的上游行为代入。

**触发与结果。** 让每日提醒实际出现，不点开或划掉；下一日已入队后查询 delivered 或删除数据。纯状态模型确认现有 delivered 枚举为空，因而取消入口拿不到通知 ID。影响包括残留已删除记录的名称或详情；设备回归重点是清除这类残留。

**修复与回归。** 分开维护 pending 和 delivered，或以 Android activeNotifications 为已显示事实来源；删除 pending 不得丢 delivered 状态。删除全部数据可额外使用 Android cancel-all 防守。设备验证要同时断言今天已显示和明天 pending 共存，然后删除数据检查通知 shade；只测单次提醒或重复入队不够。

### N11 保存界面期间进程重建丢失导出请求

来源：main 旧版本 AndroidDocuments 桥接已存在。

**优先级 P2。** Android pendingExport 只存在 companion object 的内存 File 引用里。系统 create-document 返回非空 URI 时，如果 Piru 进程已经重建，代码因源文件引用为空按取消处理，不写数据也不显示“恢复导出失败”。

**定位与证据。** [AndroidDocuments.kt 29 至 44 行及 61 至 65 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/android/app/Sources/Piru/Skip/AndroidDocuments.kt#L29-L65)；[同文件 136 至 147 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/android/app/Sources/Piru/Skip/AndroidDocuments.kt#L136-L147)；[Main.kt 95 至 98 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/android/app/Android/app/src/main/kotlin/Main.kt#L95-L98)。

**触发与结果。** 发起 JSON 导出，在系统保存界面停留，后台 Piru 进程因低内存被回收；用户完成保存，ActivityResult 交给重建 activity，但源描述已丢失。源路径缺失导致未写出是确定的源码行为；是否残留零字节目标取决于提供方的创建语义，不能一概声称所有提供方都留下空文件。临时源文件可能还在，但没有恢复索引。

**修复与回归。** 启动选择器前持久保存 request ID、源描述和类型，并在处理返回值前恢复。非空 URI 加缺失源应报告失败或恢复，不等于用户取消；按提供方能力清理空目标。用后台进程 kill 而不是 force-stop 做设备验证，比较正常完成与进程重建后的字节数、JSON 有效性和明确错误反馈。

### N12 全历史 Timeline 存在平方级主线程扫描

来源：main 旧版本已有两处扫描，移植前 1.6 及本次 performance build 均继承。

**优先级 P2，性能算法缺陷。** TimelineStripBuilder 对所有有记录的日期加今天构建 dayDates，不是仅处理可见窗口。在每个日期循环中重新执行 last(where:) 找相邻较新日期，产生 Θ(N²) 比较。该 builder 的 init 在 MainActor 上，发生在 progressive 更新首次 yield 之前；后面的分批发布不能分散这段初始工作。

**定位与证据。** [TimelineStripBuilder.swift 196 至 205 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Views/Journal/TimelineStripBuilder.swift#L196-L205)；[同文件 239 至 245 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Views/Journal/TimelineStripBuilder.swift#L239-L245)；[UnifiedTimelineView.swift 218 至 252 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Views/Journal/UnifiedTimelineView.swift#L218-L252)。[EntryListView.swift 371 至 411 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Views/Journal/EntryListView.swift#L371-L411) 的正常未过滤入口传入完整 entries，不能借其他 JournalModel 的分页边界排除此路径。

**第二处重复工作。** 渐进发布在前 10 个 slice 后、以后每 6 个 slice 执行 previous.filter，重新扫描全部旧布局，再合并 built。等规模旧新历史下，又是 N 乘发布次数的工作。记录修改、布局变化以及活跃时每 5 分钟 clock tick 都可触发重建；并非只有首启一次。

| 有记录日期数 N | 相邻日期查询比较数 | 渐进发布次数 | 旧布局 filter 检查数 |
|---|---|---|---|
| 30 | 494 | 4 | 120 |
| 365 | 67159 | 60 | 21900 |
| 3000 | 4504499 | 499 | 1497000 |

这些是按现有控制流独立计算的操作次数，不是设备 benchmark，不能推导具体卡顿毫秒、帧率或耗电。它们足以证明完整历史增长时，主线程工作量不是线性；尚未测某个真实用户规模是否达到可感知卡顿。

**修复与回归。** 用相邻索引或前一循环值取得 newer date；对已排序 previous 保持单调 frontier 索引，避免每次全扫。先做 30、365、3000 日的确定性操作次数回归，要求近线性增长，再记录设备延迟及取消响应。现有时间映射和曲线几何 helper 测试不能覆盖完整 builder 的规模行为。

## 旧问题与已知边界复核

下列问题不是新发现。K01、K02、K03、K04 分别对应旧 CHANGES 的 D708-4、D708-6、D708-8、S3；K05、K06 对应旧审计 P01、P02；K07 对应此前已说明未完整覆盖的手动导出边界。当前调用链已重新检查。

### K01 临时恢复库仍可覆盖健康自动备份

**P1，旧问题仍在。** 持久库打不开时 StoreRecovery 标记 storeUnavailable 并返回临时内存库。启动结束后仍可后台化；文件夹备份只检查配置、间隔和数据可读性，不检查库来源。可读但空或不完整的临时库通过 completeness guard，再以新 revision 替换原文件夹副本。间隔是距上次备份的时间，不必是本次启动后再等 30 秒。

**定位。** [StoreRecovery.swift 146 至 154 行及 194 至 219 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Data/Persistence/StoreRecovery.swift#L146-L219)；[FolderBackup+Android.swift 108 至 140 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/android/app/Sources/Piru/Android/Backup/FolderBackup+Android.swift#L108-L140)。

**修复和回归。** 备份 API 携带 canonical 持久库健康与来源，fallback 状态禁止自动发布并显示暂停。人工制造打不开的持久库，完成 fallback 启动并后台化，断言旧副本字节和 revision 不变。原数据库及恢复文件可能仍保留，因此不是“所有副本必然毁灭”；供应方历史恢复能力也不由应用保证。

### K02 编辑后删除再回滚未恢复被删除对象的旧值

**P2，旧问题仍在，限 PortableData 的 mutation-tracked 已保存模型。** 编辑把 ID 放进 touched；delete 又把它移出；rollback 重注册 deleted 对象，却只恢复 candidates 的 baseline。因此保存值 10 → 未保存改 20 → delete → rollback 后，内存仍为 20、磁盘仍为 10、hasChanges 为 false。以后改备注再保存还可能将 20 一起落盘。

**定位。** [ModelContext.swift 284 至 291 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/android/Compat/Sources/PortableData/ModelContext.swift#L284-L291)；[同文件 342 至 368 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/android/Compat/Sources/PortableData/ModelContext.swift#L342-L368)。

**修复和回归。** 恢复 deleted 对象时同时还原 baseline，或将其加入回滚集合。断言 held reference、fresh context、hasChanges 和下一次无关保存一致。独立模型包含 untracked 负对照；现有测试分别测 edit→rollback 和 delete→rollback，没测同一对象组合序列。Swift 回归草稿尚未执行。

### K03 旧自定义物质迁移失败后仍删除唯一迁移来源

**P1，旧问题仍在。** 有效旧 defaults blob 插入到 context 后，save() 用 try? 吞错；同一个 context 的 fetch 可以读到 pending inserts，按名称判断“迁移成功”，随后删除旧 blob。进程退出会失去未持久化记录和重试源。临时 fallback context 也存在同类来源判断问题。

**定位。** [CustomSubstance.swift 589 至 599 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Domain/CustomSubstance.swift#L589-L599)；[同文件 633 至 656 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Domain/CustomSubstance.swift#L633-L656)。

**修复和回归。** 必须成功写入 canonical 持久库，并由独立持久读取确认后才移除 blob。注入 save 失败并重启，断言旧字节保留、可再次迁移。这里确认的是有效 blob 在保存失败后的丢失，不用“不可解码 blob 被主动清理”直接冒充可恢复数据已损坏。

### K04 活跃 WAL 分步复制不是一致快照

**P1，旧条件性竞态，已用实际 SQLite 重现。** snapshotStore/copyStore 分别复制主文件和 WAL。若主文件复制后另一连接 checkpoint 并截断 WAL，副本得到旧 main 加空 WAL：文件可读、完整性检查可通过，却遗漏快照开始前已提交的数据。replace 恢复依赖此安全副本，因此风险在失败后恢复能力。

**定位。** [StoreRecovery.swift 358 至 383 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Data/Persistence/StoreRecovery.swift#L358-L383)；[同文件 496 至 511 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Data/Persistence/StoreRecovery.swift#L496-L511)。

**实验和修复。** 临时 SQLite 测试库中，实时已提交量为 200，复制结果为 100；这是实际数据库文件行为，不是只用字典演示。生产应用并发时机未实测。改用 SQLite online backup 或 GRDB backup 到独立 staging 库后原子发布，或证明所有连接完全静止。测试必须是真实 WAL/checkpoint 交错，复制几个同名假字节文件不能覆盖。

### K05 跨时区后历史重算丢失 occurrence 关联

**P1，旧 P01 仍在。** dueDay 存储旧时区午夜的绝对 Date，历史重算却以当前 Calendar 对日志分日并精确 Date join。换区后再导入或更改日界触发修复，匹配可为空，把 logged 改 missed 并清 satisfyingEntryID；DoseEntry 本身没有删除。

**定位。** [CalendarSessionDay.swift 49 至 51 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Shared/CalendarSessionDay.swift#L49-L51)；[RoutineOccurrenceService.swift 71 至 97 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Data/Services/RoutineOccurrenceService.swift#L71-L97)。

**边界与回归。** Edmonton 的 2026-10-29 日键为 06:00Z，Vancouver 对同条日志得到 07:00Z。仅切时区不一定立即重算；同一命名时区正常 DST 过渡也不会自动改变过去日期的午夜偏移。应迁移为带明确语义的民用日期身份，别简单对旧 Date 再取当前 startOfDay。测换区后导入、改日界、跨日期线及 DST 历史日期，断言日志 UUID 和 occurrence 关联稳定。

### K06 QuickLog 仍将已跳过时段显示为待服

**P2，旧 P02 仍在。** DueNowSlot 和 remaining 仅数 DoseEntry，没有 occurrence/skip 输入。单日 08:00 时段执行 Skip Today 后无日志，QuickLog 与 dock 仍可能显示 due。它不会自动创建剂量记录，不能把误导标签写成后台自动补记。

**定位。** [QuickLogModels.swift 284 至 302 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Views/QuickLog/QuickLogModels.swift#L284-L302)；[同文件 679 至 717 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Views/QuickLog/QuickLogModels.swift#L679-L717)。

**修复和回归。** 与 N08 一起改为读取 occurrence，logged 和 skipped 都从当前待办中排除。测 skip、undo、早 skip 晚 pending、其他日期和途径不受影响，并验证刷新后的显示而不只验证 revision 变化。

### K07 手动导出仍没有完整可读性保护

**P2，旧保护范围的剩余边界。** 自动备份会检查不可解码行，手动原生 JSON 和加密导出直接走普通 export。PortableData 跳过坏行返回可读子集，UI 仍用普通成功文件的流程，没有 partial 标记。导出动作不删除原数据库；风险是用户误用不完整文件作迁移或卸载前唯一副本。

**定位。** [BackupManager.swift 154 至 155 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Data/Backup/BackupManager.swift#L154-L155)；[DataExportImport.swift 45 至 76 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Utilities/DataExportImport.swift#L45-L76)。

**修复和回归。** 完整备份和原生导出共用 readability guard；若允许部分抢救，明确标记缺失行数并保留原始恢复库。注入一条不可解码行，从真实两个手动入口导出，断言拒绝或明显 partial，而不是只测 checkedBackup helper。

## 构建验证与可复现性

### B01 APK 成功不再要求同提交回归成功

**P2，验证门禁缺口。** performance workflow 的 cache-regression 和 android 由 cache_only 互斥选择，默认 APK 路径跳过测试，也没有 needs 或历史成功验证。普通 perf-1.6 push 不会自动获得 main 或 PR 的 ci.yml 覆盖。

**定位。** [piru-performance.yml 12 至 46 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/.github/workflows/piru-performance.yml#L12-L46)。[f325456 提交](https://github.com/bluepoison42/piru-performance-build/commit/f325456d82db80016013c88bec8103fe244d2a2f) 删除了 exact-commit tests 验证步骤。

**修复与验证。** 用 tests → android needs: tests，或恢复严格 SHA 绑定的成功校验；允许无门禁的性能包时必须与发布路径区分。用一次故意失败的回归证明 APK 任务被阻止，另验证合法成功和并发运行不会串 SHA。本项不表示已构建 APK 一定坏了。

### B02 声明的 Gradle wrapper 没有用于打包

**P2，可复现构建缺口。** wrapper 声明 Gradle 9.0.0，CI 却安装无版本 Homebrew gradle，package-apk.sh 调全局 gradle 而非 wrapper。同提交换机器或稍后重建可能使用不同工具链。

**定位。** [gradle-wrapper.properties 第 1 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/android/app/Android/gradle/wrapper/gradle-wrapper.properties#L1)；[setup_ci.zsh 第 15 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/ci/perf/setup_ci.zsh#L15)；[package-apk.sh 28 至 29 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/android/tools/package-apk.sh#L28-L29)。

**修复与验证。** 使用经过摘要校验的固定 distribution/wrapper，运行时断言版本，把实际版本写入产物 provenance。用两条不同 PATH 的环境验证不会选中错误全局 Gradle。这里没有发现供应链入侵。

### B03 依赖校验只覆盖部分 vendored pins

**P2，可复现构建缺口。** 路径相关 originHash 可触发重新解析；verify_pins 只检查 6 个 vendored 包，锁文件共 23 个包，剩余 17 个没有全图比对门禁。记录解析结果是可观测性，不是拒绝漂移。

**定位。** [stage.py 270 至 275 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/android/tools/stage.py#L270-L275)；[verify_pins.py](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/ci/perf/verify_pins.py)；[build-app.sh 28 至 29 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/android/tools/build-app.sh#L28-L29)。

**修复与验证。** 每次 resolve 后比对所有非 vendored identity/revision 与批准锁，vendored 包另比对确定的补丁基线。每个 APK 留存完整实际依赖图。用不在六包列表里的人工 pin 漂移证明校验拒绝。b64edd7 到 bad4aa1 的已提交 pins 实际未变，只有 originHash 变化；本报告不声称本次 APK 已发生依赖升级。

### 已核对的 CI 证据

| 源提交 | 运行 | 已核对结果 | 不能据此推导 |
|---|---|---|---|
| b64edd7 | 41133225837 | 回归测试运行成功 | 后续 bad4aa1 测试通过 |
| b64edd7 | 41135335108 | 当时带门禁的 APK 构建成功 | 当前门禁仍存在 |
| f325456 | 41167899858 | APK 构建成功，cache-regression 跳过 | 冻结 bad4aa1 同 SHA 已测试 |

运行链接：[b64 回归](https://github.com/bluepoison42/piru-performance-build/actions/runs/41133225837)，[b64 构建](https://github.com/bluepoison42/piru-performance-build/actions/runs/41135335108)，[f325 构建](https://github.com/bluepoison42/piru-performance-build/actions/runs/41167899858)。这是已核对的历史状态，不替代对后续修复提交重新取证。

宿主 Compat 测试确实覆盖部分 substitution-staged 生产模型与服务，有价值，但不运行完整 Android patch/template/Skip/Compose 链。APK job 有 native/转译/Gradle 构建及 ABI、libPiru.so 检查，没有安装启动、系统通知、SAF 或交互回归。性能 APK 有意未签名，不作为安全漏洞。修复验收应保存同 SHA 的测试结果、依赖图、工具链版本、APK 哈希及设备用例记录。

## 条件性候选与后续验证

这些候选没有计入 12 项主确认。源码可疑程度和产品触达证据不同，先补最短反例或真实平台验证，不宜直接当发布事故。

### C01 嵌套组合按不透明成分记录

**候选 P2。** 选择器可将已有组合投影成普通 Substance；外层 staging 只遍历一层，不展开内层。人工建立 Inner 含 A/B，再把 Inner 加入 Outer，预期路径会记录 Inner 1 pill 而非 A/B。是否允许嵌套组合以及应如何计量需明确产品约束。

**定位。** [MedProductForm.swift 319 至 327 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Views/Journal/DailyDose/MedProductForm.swift#L319-L327)；[DoseTray.swift 820 至 834 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Views/QuickLog/DoseTray.swift#L820-L834)。先做 UI 保存重开及实际日志验证；若不支持嵌套，就在编辑和导入共同拒绝。若支持则需显式展开、单位转换和循环检测。当前不是无限递归 bug，代码根本没有递归。

### C02 提醒同步任务可能重新加入过期请求

**条件性竞态 P2。** [DoseNotificationManager.swift 551 至 631 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Utilities/DoseNotificationManager.swift#L551-L631) 每次同步发起异步 sweep/add；generation 只保护 journal reset，不代表普通 schedule 版本。独立 fake-center 时序中，旧任务等 pending，较新 disable 已清理结束，旧任务恢复后重新 add。真实 OS 上的发生频率未测。

建议串行合并调度或在每个 await 后校验递增 schedule revision，设备压力测试开关提醒及 skip，并等待所有异步任务结束后核对系统 pending。取消旧 Task 但不清理过期外部写入未必足够。

### C03 唯一键重映射未同步重写关系字节

**框架候选 P2。** [ModelContext.swift 390 至 445 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/android/Compat/Sources/PortableData/ModelContext.swift#L390-L445) 先编码关系，后在 [579 至 633 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/android/Compat/Sources/PortableData/ModelContext.swift#L579-L633) 对 unique upsert 重映射父行 ID，但已编码 child 关系仍指向旧新建 ID。fresh reader 可读出 nil 关系。

原生 Session 导入通常先复用已有 UUID，避开最直接触发，所以不写成普通导入必丢 session。先执行已拟定的真实 PortableData 父唯一键冲突加新 child 回归，断言 fresh context 关系；确认正常产品调用或并发暴露后再提升主问题。

### C04 同身份同时间的两个用药计划共享 occurrence

**产品语义候选 P2。** [RoutineOccurrenceService.swift 250 至 255 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Data/Services/RoutineOccurrenceService.swift#L250-L255) 以 substance、route、time 去重，不含稳定计划 ID。UI 可创建同物质同时间、量不同的两计划，一条日志可使两行都 taken。

先决定重复计划是必须合并，还是独立目标。如果独立，occurrence 需稳定计划身份而非可变 sortOrder；如果不允许，应在编辑和导入明确处理。回归要检验 amount/product 不同的两计划以及 skip 对单行的含义。

### C05 旧菜单跨日界及历史通知动作

**待平台证据。** [MyMedsCard.swift 282 至 289 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/Piru/Views/Journal/DailyDose/MyMedsCard.swift#L282-L289) 的 skip 操作按当前日执行。需验证 03:59 打开菜单，04:01 点击时平台是否保留旧菜单。若保留，动作应携带日身份并拒绝过期。旧 iOS delivered notification action 也需同类检查；Android 当前没有这些 action button，不能把它算作 Android 缺陷。

### C06 增量转译缓存与实际依赖来源

**构建候选。** [stage.py 728 至 768 行](https://github.com/bluepoison42/piru-performance-build/blob/bad4aa1c8aa6c085dc468d23ae1ac3607113bd1d/android/tools/stage.py#L728-L768) 会清部分 SwiftPM 状态，但保留某些 Kotlin/Gradle 产物。仓库工程规则记录过此类问题；新 CI runner 降低当前暴露，不能据此认定现有 APK 带旧 Kotlin。用 disposable workspace 修改无害 vendor sentinel，断言 generated Kotlin 和最终 DEX 同步，再确定自动失效策略。

同理，tag 固定不等于独立上游 SHA allowlist，部分下载缺少固定摘要，Actions 用 major tag。这些属于加固建议，没有发现恶意供应链证据。

### C07 低优先级边界输入与缓存

ByVolume formatTrimmed 把极大的有限 Double 转 Int，需验证实际 Swift 溢出和 UI 可达范围；Timeline 颜色依赖遗漏已进一步确认，但影响较低且继承自 main：只改颜色不会改变实时 task key，持久 strip key 也无 colorSignature，因此在下一次 5 分钟 tick 或其他重建前可显示旧色，30 分钟缓存窗口内重启也可能恢复旧色。应同时给实时及持久 key 加色彩 signature，并测试仅颜色变化、同剂量 revision 的情形。源数据优先级遗漏仍未单独提升；这不是永久冻结或记录内容损坏。应用创建的明文 import cache 在删除后是否残留，需先明确“删除全部”的覆盖范围和清理承诺。这些均未计为已确认隐私泄露或主数据缺陷。

## 已排除或缩小的疑点

- **整组重新加入托盘不是自动 bug。** MedGroupPill 文档明确允许 Done 后重新记录；应修 Due 状态，不以此取消手动快捷方式。
- **正常 DST 不等于跨时区历史损坏。** 同命名时区会按历史日期取偏移，K05 的触发要包含实际时区身份改变及重算。
- **重复提醒不会只响一次。** Android 0017 补丁已实现循环调度以及时区和系统时钟变化后的 calendar rearm；N10 指的是 delivered bookkeeping，不是否定重复调度整体。
- **删除外部文件不是要求。** 外部备份保留是正确边界；N05 的问题是后续继续覆盖它，N10 的问题是已显示通知仍可残留。
- **原生 UUID 去重已有正确保护。** 不同 UUID 的相同内容剂量保留；重导同 UUID 不新增。旧无 UUID 格式有自己的边界，不能用新格式测试替代。
- **新 1.6 字段并非全部漏导出。** injectionSite、volume/abv/combinationName、frequencyIntervalDays 已有往返字段及默认解码测试；组合定义在 custom substances 内，不能因没有独立表就声称没备份。
- **备份加密有实际保护。** KDF 参数和盐长度校验、认证头、口令处理、包边界及错误口令先解密再破坏性恢复已检查；没有凭泛泛可能性宣称明文泄露或可绕过加密。
- **Android 文件权限没有确认的任意读取漏洞。** FileProvider 限于 cache/share、非 exported、按 Intent 授权；导入显示名处理未形成已证实路径穿越。诊断日志的表述不等于形式化脱敏保证，但没找到足够具体的日常日志泄露链。
- **PortableData 缓存并非全面失效。** revision 会清 sortedReads，willSet 中同步读造成的旧排序由 didSet 二次 noteMutation 清除，现有测试明确覆盖；谓词、计算属性排序及不报告 mutation 的模型被排除在底层缓存外。没有另立“willSet 必然 stale”或 JNI 泄漏结论。
- **产品编辑保留历史快照属合理行为。** 改组合强度不会自动重算历史已记量；普通 UI 不允许把现有 solid/liquid 类型随意互换。注射部位路由校验和轮换、搜索规范化未形成具体新缺陷。

## 回归验收清单

### 数据及恢复

- 对 N01、N02、N04，断言实际持久化后读回的数值、单位、身份和元数据，不只断言显示字符串或纯函数。
- 对 N05、N06、K01、K03，注入真正的保存失败、fallback 来源、删除与后台化交错；旧备份内容必须在失败条件下保持可解密和字节稳定。
- 对 K02、C03，使用生产 PortableData 模型，并比较 held reference、fresh context 和重启后结果。
- 对 K04，使用实际 WAL 库和另一连接 checkpoint；验证快照包含开始前已提交值而不是仅 integrity_check 成功。
- 对 K07，分别从明文和加密手动入口触发坏行情况，确保普通成功状态不会掩盖 partial。

### 日程及平台

- N07 必须验证所点时段 UUID，被保留的其他时段和非计划记录也要有断言。
- N08、N09、K05、K06 覆盖多时段、skip、同数量改时间、跨时区、日界、日期线；对照同一个 occurrence 真值。
- N10 用真实 NotificationManager 验证已显示和未来 pending 共存及删除后的系统状态。
- N11 用低内存式后台进程终止、至少一个本地和一个外部提供方，验证请求恢复及明确错误；不要用 force-stop 代替系统重建流程。
- C02 用可控 fake center 做确定性交错测试，再做设备压力回归，二者结果分别记录。

### 性能及 A B 对照

N12 用全历史且不带搜索过滤的正常入口，分别记录初始构建与渐进发布阶段，不用只有当前可见行的测试替代。颜色问题单独测试 color-only 修改。Android 默认 next mask 为 0、shadowMode 为 2、contentCapture 为 false；不带 extra 的启动是降采样阴影模式，不是旧全分辨率基线。设备对照报告必须记录实际 Intent extras 和默认模式；这些默认值本身不是已证实的视觉 bug。

### 构建与交付证据

修复提交应提供同 SHA 的测试日志、实际依赖清单、构建工具链和 APK 哈希。宿主单测、原生编译、转译成功、设备功能通过是四种不同证据，报告时不要合并为一个“全通过”。当前 Swift 草稿与现有测试阅读不计作任何通过数量。

## 附录 复现证据与状态

独立复现使用人工数据和独立实现的最小分支，不导入或运行项目生产代码。以下状态区分算法论证、真实数据库实验和未执行的生产回归，避免把“有测试代码”写成“测试已通过”。

| 复现范围 | 方式 | 本次状态 |
|---|---|---|
| N01 N02 N03 | 独立 Python 舍入 缩放和序列化模型 | 已执行 |
| N04 K02 C03 | 独立 Python 合并及 rollback 身份模型 | 已执行，含 untracked 负对照 |
| K04 | 标准 SQLite 临时 WAL 库 加另一连接 checkpoint | 实际数据库实验已执行 |
| N07 N08 K05 K06 | 独立 Python 日期键及槽位选择模型 | 已执行 |
| C02 | 可控异步 fake center 的旧新同步交错 | 已执行，非真实 OS 通知中心 |
| N10 | 独立 pending 与 delivered 索引状态模型 | 已执行，非设备通知实验 |
| N12 | 按两个循环实际分支计数 | 已执行，非性能 benchmark |
| K02 C03 生产回归 | PortableData Swift 测试草稿 | 未编译 未执行 |
| 全部 UI 及平台回归 | Swift Android SAF NotificationManager Compose | 未执行 |

### 主要证据输出

- 按体积：0.25 × 1 = 0.25，现有分支得 0.3；0.04 得 0 并禁止提交。
- 液体组合：1 mL → 5 mL 后普通成分按 5 倍更新，被排除的成分仍是原量。
- 库存：本地 100 mg 加导入 1 g，原分支得到 101 mg，按单位正确应为 1100 mg。
- 回滚：tracked 对象保留改后值且 hasChanges false；untracked 负对照恢复原值。
- SQLite：实时已提交 200，分步快照恢复为 100；实验使用临时人工库。
- 日程：只有晚段记录时，occurrence 已服晚段而 QuickLog 仍称晚段 due；点击早段撤销选择最新晚段 UUID。
- 重复通知：模型中的可见状态与 delivered 枚举分离后，删除全部流程仍留可见状态；不是设备截图，也不是重复通知堆积的证据。
- Timeline：3000 日独立计数为 4504499 次邻居查询比较及 1497000 次旧布局过滤检查；没有换算为设备延迟。

### 历史材料

[旧审计报告](https://github.com/bluepoison42/piru-audit/blob/8605b11ce6287335089a98523438a9b6c4fb20a9/reports/%E5%AE%A1%E8%AE%A1.md)，[旧已知问题列表](https://github.com/bluepoison42/piru-audit/blob/8605b11ce6287335089a98523438a9b6c4fb20a9/old-reports/CHANGES.md#L448-L486)。本轮对旧问题重新追踪当前代码，但未据此声称已经完成修复或运行回归。
