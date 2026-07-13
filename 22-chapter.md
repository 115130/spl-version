# 第 22 章 · 云平台接入、设备身份与 HMAC（SPL版）

> **本章产出**：能解释设备“三元组”、签名和时间戳的作用；为设备设计不会泄露密钥的上云配置方式。
>
> **前置知识**：第 21 章 MQTT。
>
> **用在哪**：任何需要把设备接入公有云或自建平台的项目。
>
> **实验边界**：本章先用公开演示 Secret 和离线测试向量验证“字节是否一致”；真实平台的字段、编码、签名算法和 TLS 能力必须以该平台官方文档为准。

---

## 22.1 云平台到底替你做了什么

MQTT Broker 只负责收发消息。云平台通常还提供设备管理、权限控制、数据存储、规则引擎、告警和可视化。它的核心问题是：

> Broker 如何确认“这块 STM32 真的是 room-01 的那块设备”？

因此，设备首次接入前必须有唯一身份，并且每次连接都要证明自己拥有对应密钥。

## 22.2 认识设备三元组

很多 IoT 平台把设备身份称为“三元组”：

| 信息 | 含义 | 是否能公开 |
|---|---|---|
| Product Key / Product ID | 产品或设备组标识 | 通常可以 |
| Device Name | 单个设备名称 | 通常可以 |
| Device Secret | 设备私钥 | 绝不能公开 |

不同平台字段名称不完全一样，但原则相同：前两个用于定位设备，最后一个用于证明身份。

**重要规则**：不要把 Device Secret 写进 README、截图、公开 Issue 或 Git 历史。即使后来删除文件，旧提交中也可能仍然有密钥。

## 22.3 HMAC：不用发送密钥，也能证明你知道密钥

HMAC 是“带密钥的摘要”。设备和云端各自保存同一个 Secret，设备把一组规定字段与 Secret 一起算出签名；云端用同样方法再算一次，两边相同才允许连接。

~~~text
待签名内容 + Device Secret
            |
            v
      HMAC-SHA1 / HMAC-SHA256
            |
            v
         signature
~~~

签名不是加密。别人能看到待签名字段和 signature，但在不知道 Secret 的情况下，不能伪造新的有效签名。

一个通用的待签名内容可能包含：

~~~text
clientId=device-001
deviceName=room-01
productKey=demo-product
timestamp=1720000000
~~~

具体字段顺序、编码和算法必须以你选择的平台官方文档为准。不要把一个平台的签名规则机械复制到另一个平台。

## 22.4 配置文件与源码分离

教材示例可以使用占位配置，但真实密钥应该放在不提交的本地文件中：

~~~c
/* device_config.h.example：可以提交 */
#define DEVICE_PRODUCT_ID  "replace-me"
#define DEVICE_NAME        "replace-me"

/* device_config.h：仅本地使用，不提交 */
#define DEVICE_SECRET      "your-secret-here"
~~~

在 .gitignore 中加入：

~~~text
device_config.h
wifi_credentials.h
~~~

对于量产设备，更好的方式是在烧录或产线配置阶段写入设备专属区域，而不是让所有设备共享一个 Secret。

## 22.5 从连接到上报的完整顺序

~~~text
1. 从本地读取设备身份与密钥
2. 生成 timestamp 和 clientId
3. 按平台规则计算 HMAC
4. 建立 TCP 和 MQTT CONNECT
5. 等待 CONNACK
6. 发布 status=online
7. 定时发布遥测数据
~~~

每一步都应能在串口日志中看见“成功/失败原因”。日志可以记录错误码和状态，但不要打印完整 Secret 或完整签名原文。

## 22.6 数据模型先于云端代码

云端最难返工的往往不是网络，而是字段命名。为环境监测设备先约定一个稳定的数据模型：

~~~json
{
  "device": "room-01",
  "seq": 42,
  "temperature_c": 24.6,
  "humidity_rh": 58.0,
  "battery_mv": 3920
}
~~~

建议：

- 物理量和单位写在字段名中；
- 不要同时用 temp、temperature、t 三种名字；
- 对连续上报的数据带上 seq 或 timestamp；
- 新字段应保持向后兼容。

## 22.7 安全检查清单

- [ ] 仓库与文档中没有真实 WiFi 密码、Device Secret 或访问令牌；
- [ ] 每台量产设备使用独立 Secret；
- [ ] 连接失败日志不泄露密钥；
- [ ] 平台支持 TLS 时，评估内存、证书和模块固件能力后启用；
- [ ] 密钥泄露后有撤销和重新配发流程。

## 22.8 本章练习

1. 用占位符完成一份 device_config.h.example；
2. 为 room-01 设计三元组和五个遥测字段；
3. 故意使用错误签名，记录云端的拒绝现象；
4. 检查 Git 历史，确认没有误提交任何真实密钥。

## 22.9 为签名准备可重复测试

密码学代码不能只靠“看起来像对”。无论选择 HMAC-SHA1 还是 HMAC-SHA256，都应准备至少一组公开测试向量：

~~~text
输入消息：
密钥：
期望 HMAC：
实际 HMAC：
是否一致：
~~~

先在 PC 上用脚本得到预期值，再让 STM32 对同样输入计算并比较。平台接入失败时，先逐字节核对字段顺序、编码、时间戳和签名大小写，不要反复换 Secret 猜测。

真实 Secret 只存在于本地配置或安全烧录流程中；测试向量必须使用公开的演示密钥。

## 22.10 签名测试向量：先验证输入，再验证 HMAC

平台接入失败时，最常见的不是“算法坏了”，而是参与签名的字节与平台规定不同。为每个平台建立一份**公开测试向量**：

~~~text
平台/协议版本：
客户端 ID：
设备名：
时间戳：
nonce：
规范化后的待签名字符串（逐字节）：
演示 Secret（不可用于真实设备）：
期望 HMAC（十六进制大小写说明）：
实际 HMAC：
~~~

在 PC 端用标准库先得到可信答案。例如下面的 Python 片段只针对演示 Secret，不接触真实密钥：

~~~python
import hmac, hashlib

message = b"clientId=zet6-lab&timestamp=1700000000"
secret  = b"demo-secret-not-for-production"
print(hmac.new(secret, message, hashlib.sha256).hexdigest())
~~~

STM32 侧不要为了这一个项目手写 SHA-256/HMAC。选择经过审查的库或由模块/平台提供的安全能力；你要验证的是**输入字节、算法、输出编码和密钥生命周期**。

### 配置接口与密钥边界

~~~c
typedef struct {
    const char *product_id;
    const char *device_id;
    const uint8_t *secret;
    size_t secret_len;
} CloudCredentials;

/* 真正的定义放在未提交的 device_config.h；
   仓库只提交 device_config.example.h。 */
~~~

启动日志只能打印 product/device 标识和签名结果长度，绝不能打印 Secret、完整 Authorization 或含密钥的 AT 命令。

### 上云前的离线验收

| 检查 | 通过标准 |
|---|---|
| 规范化字符串 | PC 与 MCU 的长度、十六进制转储完全一致 |
| HMAC | 对同一演示输入得到相同输出 |
| 编码 | Base64/Hex 大小写、换行和 URL 编码符合平台规则 |
| 时间 | 时间戳来源、时区和有效期明确 |
| 重放 | nonce/序号或平台机制能拒绝旧请求 |
| 版本库 | `git status` 中没有真实 Secret 或生成配置 |

练习：故意只改待签名字符串中的一个 `&` 或大小写，比较两个 HMAC；你会直观看到“看起来一样的参数”为什么会导致平台拒绝。

## 22.11 平台接入失败时的排错顺序

1. 使用公开测试向量确认 MCU 与 PC 的 HMAC 一致；
2. 按官方文档逐字节比较 canonical string，不要先更换 Secret；
3. 检查时间戳、Client ID、设备名、协议版本；
4. 查看 Broker/HTTP 返回码和平台日志；
5. 最后才检查 TLS、证书、模块能力和网络。

## 22.12 本章要点

- 云平台接入的本质是“身份 + 权限 + 数据模型”；
- 三元组中 Secret 是最敏感的信息；
- HMAC 用来证明设备持有密钥，不等于加密；
- 平台规则不可想当然，签名字段必须以官方文档为准；
- 把密钥、示例配置和业务代码分开管理。

---

[上一章：第 21 章 · MQTT](./21-chapter.md)

[下一章：第 23 章 · HTTP、响应解析与 cJSON](./23-chapter.md)
