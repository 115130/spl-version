# 第 22 章 · 云平台接入、设备身份与 HMAC（SPL 版）

第 21 章已经能连接 MQTT Broker。本章处理真实平台接入时经常出错的认证链路：设备身份、待签名字节、HMAC、时间和密钥配置。

这里不绑定具体云平台。Product Key、Client ID、签名字段、编码方式、TLS 参数都以目标平台当前文档为准。本章先把认证过程拆成可离线验证的几个步骤。

## 22.1 先区分标识和凭据

IoT 平台通常会给设备分配公开标识和秘密凭据。名称各不相同，例如 Product ID、Device Name、Client ID、Access Key、Device Secret、Token 或私钥。

Product ID、Device ID 这类字段通常用于说明设备身份；Secret 或私钥用于证明设备持有凭据。具体哪些字段需要保密，由平台定义。Secret 不应出现在普通日志、MQTT Topic 或代码仓库中。

设备认证可以抽象成两部分：设备提交身份字段，同时根据平台规则生成认证数据。服务器验证认证数据以后，才接受对应身份。

## 22.2 HMAC 的输入必须逐字节一致

如果平台规定 HMAC-SHA256，可以先写成：

```text
signature = HMAC-SHA256(secret, message)
```

HMAC 算法固定以后，最常见的问题在 `message`。字段顺序、分隔符、大小写、UTF-8 编码、URL 编码和末尾换行只要有一个字节不同，结果就会不同。

把平台的待签名规则单独封装：

```c
typedef struct {
    const char *client_id;
    const char *device_name;
    const char *product_id;
    const char *timestamp;
    const char *nonce;
} CloudAuthInput;

int Cloud_BuildCanonical(const CloudAuthInput *in,
                         char *out, size_t out_size);
```

这个函数只生成待签名字节，不读取 Secret，也不访问网络。调试时可以输出长度和十六进制内容，但要先确认待签名字段本身没有平台定义的敏感信息。

例如教学规则可以规定：

```text
clientId=zet6-01&deviceName=room-01&timestamp=1700000000
```

这里只演示“固定字段 + 固定顺序 + 固定分隔符”。接真实平台时，照平台文档逐项实现，不从这个示例推断实际格式。

## 22.3 HMAC 实现要有已知测试向量

本章不手写 SHA-256 或 HMAC。使用有明确来源和版本的密码学实现，或者使用无线模块提供且文档完整的安全能力。设备侧只保留稳定接口：

```c
typedef enum {
    CLOUD_AUTH_OK,
    CLOUD_AUTH_BAD_ARG,
    CLOUD_AUTH_BUFFER_SMALL,
    CLOUD_AUTH_CRYPTO_ERROR
} CloudAuthResult;

CloudAuthResult Cloud_HmacSha256(const uint8_t *secret,
                                 size_t secret_len,
                                 const uint8_t *message,
                                 size_t message_len,
                                 uint8_t out[32]);
```

HMAC-SHA256 输出 32 字节。平台可能要求再编码成小写 Hex、大写 Hex、Base64 或其他形式；这些转换属于认证协议的一部分。

接网络前，先让 PC 和 STM32 对同一组公开测试数据得到相同结果。例如 PC 可以生成一组项目自己的回归向量：

```python
import hashlib
import hmac

message = b"clientId=zet6-01&timestamp=1700000000"
secret = b"demo-secret-not-for-production"

digest = hmac.new(secret, message, hashlib.sha256).digest()
print(digest.hex())
```

保存 `message` 的长度、十六进制、公开测试 Secret 和期望 HMAC。STM32 测试同一组字节。结果不一致时先比较输入字节，再检查算法和输出编码，暂时不要碰网络。

HMAC 提供消息认证和完整性校验，不负责加密。Client ID、canonical string、signature 等字段是否能被链路观察者看到，取决于外层传输保护；公网连接通常还需要 TLS。

## 22.4 timestamp 和 nonce 按平台规则生成

平台可能把 timestamp、nonce 或两者一起放进签名，用于限制旧认证数据被重复使用。服务器怎样检查时间窗口、nonce 是否允许重复、nonce 需要多少随机性，都属于平台协议。

如果认证依赖 Unix 时间，设备必须先有可信时间来源。F103 不会自行获得网络时间，可以使用外部 RTC、WiFi 模块提供的 SNTP/NTP 能力，或者项目定义的受控校时流程。

这里还要区分“有一个递增计数器”和“知道当前 UTC 时间”。系统运行了 300 秒，并不能推出当前 Unix timestamp。时间未同步时，状态机应停在等待时间或配置错误状态，不要填一个固定时间继续认证。

TLS 证书验证也可能依赖正确时间。如果 TLS 由 WiFi 模块完成，还要查模块的证书验证方式和时间来源，不能默认 MCU 的时间设置会自动传给模块。

## 22.5 Secret 不进入仓库

仓库可以提交非敏感配置模板：

```c
/* device_config.example.h */
#define DEVICE_PRODUCT_ID      "replace-me"
#define DEVICE_NAME            "replace-me"
#define DEVICE_CONFIG_VERSION  1U
```

本地真实配置放在被 Git 忽略的文件中：

```c
/* device_config.h */
#define DEVICE_PRODUCT_ID      "demo-product"
#define DEVICE_NAME            "room-01"
#define DEVICE_SECRET          "local-only-secret"
#define DEVICE_CONFIG_VERSION  1U
```

`.gitignore` 加入对应文件：

```text
device_config.h
wifi_credentials.h
```

如果真实 Secret 已经进入 Git 历史，只删除当前版本还不够。旧 commit、fork、缓存或 CI 日志可能已经留下副本。先在平台侧吊销或轮换该凭据，再根据仓库实际暴露范围决定是否需要清理历史。

量产时也要避免所有设备共用一个长期 Secret。每台设备独立凭据后，单台设备泄露时可以单独吊销，不必同时替换整个产品的认证信息。

## 22.6 业务代码只拿凭据接口

不要让 MQTT、HTTP、日志模块分别引用一组 Secret 宏。统一通过凭据接口取得配置：

```c
typedef struct {
    const char *product_id;
    const char *device_id;
    const uint8_t *secret;
    size_t secret_len;
    uint32_t config_version;
} CloudCredentials;

const CloudCredentials *CloudCredentials_Get(void);
```

启动日志只输出排错需要的非敏感字段：

```c
void Cloud_LogIdentity(const CloudCredentials *c)
{
    printf("[cloud] product=%s device=%s config=%lu secret_len=%u\r\n",
           c->product_id,
           c->device_id,
           (unsigned long)c->config_version,
           (unsigned)c->secret_len);
}
```

完整 Secret、Authorization、带凭据的 AT 命令都不应进入普通日志。签名值是否允许记录也要看平台威胁模型；生产固件通常没有长期记录完整认证材料的必要。

## 22.7 认证状态机把错误分层

把认证接入第 21 章的通信任务后，可以使用下面的顺序：

```text
LOAD_CONFIG
    ↓
GET_TIME / PREPARE_NONCE
    ↓
BUILD_CANONICAL
    ↓
CALCULATE_SIGNATURE
    ↓
TCP/TLS_CONNECT
    ↓
MQTT_CONNECT_WITH_AUTH
    ↓
WAIT_CONNACK
    ↓
ONLINE
```

每个阶段保留独立错误原因。例如 canonical 缓冲区不足、HMAC 失败、DNS 失败、TLS 证书错误、TCP 超时和 MQTT CONNACK 拒绝，不要统一压成 `connect failed`。

重试策略也取决于错误类型。无线暂时断开、DNS 超时等问题可以进入有上限的退避；凭据被拒绝、设备被禁用或本地配置缺失通常不会靠每秒重连恢复，应停止快速重试并等待配置修复。

## 22.8 TLS 放在哪一层

STM32F103ZET6 有 64 KB SRAM，本书的网络链路又经过 AT 模块。接入真实 HTTPS/MQTT TLS 平台前，先确认 TLS 由谁实现。

常见结构包括：

- MCU 生成 HMAC 等认证字段，WiFi 模块建立 TLS 连接；
- 模块同时提供 TLS 和平台相关认证命令；
- 隔离局域网内使用明文 TCP 做协议实验，只传公开测试数据。

如果 TLS 由模块处理，要检查目标 TLS 版本、SNI、CA/证书加载、服务器名验证、证书有效期检查和错误码。模块能够建立一个加密 socket，不代表它已经正确验证服务器身份。

还要验证失败路径：错误 CA、错误服务器名、过期或时间无效的证书应该怎样报错。记录模块型号和固件版本，因为同一硬件的不同 AT 固件可能支持不同的 TLS 功能。

## 22.9 数据模型沿用前面的单位

云端 Payload 继续使用前面章节定义的定点单位，例如：

```json
{
  "device": "room-01",
  "seq": 42,
  "temperature_centi": 2460,
  "humidity_permille": 580,
  "battery_mv": 3920
}
```

`temperature_centi=2460` 表示 24.60 °C，`humidity_permille=580` 表示 58.0% RH。状态无效时不要伪造一个正常数值，继续携带传感器状态字段或使用平台数据模型规定的无效表示。

平台要求另一套字段名或单位时，在云适配层转换。传感器驱动和内部 `EnvSample` 保持原来的定义，避免 MQTT、HTTP、本地日志各自维护一套物理量语义。

## 22.10 凭据需要能轮换和吊销

设备身份至少要能关联这些信息：设备 ID、固件版本、配置版本和当前凭据状态。平台侧还要知道某个旧凭据是否已经吊销。

STM32F1 的读保护可以提高直接读取 Flash 的门槛，但不要把普通 MCU Flash 当作专用硬件安全根。产品的攻击成本较高时，需要根据威胁模型评估安全元件、受控烧录、调试接口策略和平台最小权限。

设备丢失或 Secret 泄露后，应在平台侧吊销旧凭据并配置新凭据。轮换流程本身也要能识别版本，避免设备继续使用已经失效的旧 Secret 无限重试。

## 22.11 排错按数据流向走

认证失败时按下面的顺序检查：

1. 用公开测试向量确认 MCU 的 HMAC 与 PC 一致；
2. 比较 canonical string 的长度和逐字节内容；
3. 核对字段顺序、大小写、UTF-8、URL/百分号编码和 Hex/Base64 规则；
4. 检查 timestamp、nonce、Client ID、Device ID 和配置版本；
5. 检查 DNS、TCP/TLS 的具体错误；
6. 检查 MQTT CONNACK 或平台返回的认证错误码。

如果 canonical string 已经不同，换 Secret 或反复重连不会解决问题。先让待签名字节和平台示例一致，再进入下一层。

## 22.12 本章完成标准

完成下面几项即可结束本章：

- `device_config.example.h` 可以提交，真实凭据文件被 Git 忽略；
- PC 和 STM32 对同一组公开 HMAC-SHA256 测试向量得到相同结果；
- 改变 canonical string 中一个字节后，测试能发现签名变化；
- 时间未同步时，认证状态机不会生成伪造 timestamp 继续连接；
- 凭据被拒绝时停止快速重试，并留下明确错误状态；
- 启动日志只包含排错需要的非敏感身份和配置版本；
- 网络任务能区分配置、时间、签名、TCP/TLS 和 Broker 认证错误。

这些边界明确以后，再针对具体云平台实现字段拼接、认证参数和 TLS 配置。平台文档变化时，只需要修改云适配层和对应测试向量。

> **上一章**：[第 21 章 · MQTT](./21-chapter.md)
>
> **下一章**：[第 23 章 · HTTP、响应解析与 cJSON](./23-chapter.md)
