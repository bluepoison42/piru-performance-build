# Piru 1.7 移植交付

[官方 1.7](https://github.com/kageroumado/piru/releases/tag/android-v1.7) 主要新增统一日界、补记服药时间和记录时区、与既往仍在起效的剂量检查交互，并修正数字输入、剂量数据与资料来源。

重叠部分采用官方实现：日界与夏令时、日分组、凌晨槽位排序、补记时间、按记录 UUID 撤销；删除我们对应的重复算法和撤销实现。保留并合入跳过／撤销跳过、跳过不计依从性、无标点搜索、组合身份与液体精度、库存换算、导入去重、备份保护及性能修复。待服状态同时认识官方新增的时区和指定服药槽位。逐项取舍见 `reports/Piru-1.7-对账.md`。

数据：1.7 新增的记录时区和服药槽位均为可空字段，旧记录缺失时读为 nil，不猜测原时区。旧格式 SQLite 测试库经真实 ModelContainer 打开、保存、重开后，记录 ID、剂量、时间、会话、日程、跳过状态及服药关联保留；原生导出往返及指定槽位与跳过组合的回归也通过。

代码分支 `perf-1.7`，APK 源码 `1884e1a4`。[CI 已通过](https://github.com/bluepoison42/piru-performance-build/actions/runs/41702511553)：运行合并相关的现有官方与移植测试，完成 Android Swift／Kotlin 编译及 APK 打包。实际依赖锁与 70015 一致；物质库与官方 1.7 清单一致。

APK：`W/outputs/Piru-performance/70016/Piru-Perf-1.7.1-70016.apk`。原密钥签名，版本 **1.7.1 / 70016**；测试版包名、名称、profileable、证书及 16 KiB 对齐已核对。

SHA256：`f5d4b7fc8809ed8c0fc21bf183a21c17e4199e643aeb3b07c6ef642c7793156c`

手机未连接，覆盖升级及界面交互留到连接后实测。
