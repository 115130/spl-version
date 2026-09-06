# 第 22 章 · 云平台接入、设备身份与 HMAC（SPL 版）

第 21 章已经能连接 MQTT Broker。本章继续处理真实平台接入时最容易出错的一层：设备身份、待签名字符串、HMAC、时间戳以及密钥配置。

这里不绑定某一家云平台。字段名、排序、编码、签名算法、TLS 和认证参数都必须以实际平台文档为准。本章先建立一套能离线验证的做法。

## 22.1 设备身份包含哪些东西

很多 IoT 平台会给每台设备分配一组身份字段。常见形式包括 Product ID、Device Name 和 Device Secret，也有平台使用 Client ID、Access Key、Token 或证书。

其中公开标识和 Secret 的角色不同：

- Product ID / Product Key：标识产品或设备组，通常不是秘密。
- Device Name / Device ID：标识具体设备，通常也不是秘密。
- Device Secret / private key：用于证明身份，必须保密。

平台接入时，设备先告诉服务器“我是谁”，再用 Secret 生成签名证明自己持有对应密钥。Secret 本身不应该直接出现在 MQTT Topic、普通日志或仓库里。

## 22.2 HMAC 验证的是一串确定的字节

HMAC 可以表示成：

```text
signature = HMAC(secret, message)
```

真正容易错的往往是 `message`。平台可能要求把 client ID、设备名、时间戳、nonce 等字段按固定顺序拼接，再做 URL 编码、大小写转换或 Base64。少一个 `&`、字段顺序不同、换行不同，HMAC 都会完全变化。

先把平台规则单独封装成 canonical string 生成函数：

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

这个函数只负责生成平台规定的待签名字节，不读取 Secret，也不访问网络。调试时可以安全输出 canonical 的长度和十六进制内容，只要其中没有敏感字段。

例如某个平台的演示规则可能要求：

```text
clientId=zet6-01&deviceName=room-01&timestamp=1700000000
```

这只是示例。字段顺序、分隔符和编码必须跟实际平台文档一致。

## 22.3 HMAC 不要自己临时手写

如果平台要求 HMAC-SHA256，可以使用经过审查并有明确版本的密码学实现，或者使用无线模块已经提供并且文档完整的安全能力。本书不把自写 SHA-256/HMAC 当作入门路线。

设备侧接口可以保持简单：

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

签名结果后续可能需要转成十六进制、Base64 或 URL 编码。输出格式同样属于平台协议，不能只算出 32 字节 HMAC 就认为认证字符串已经完成。

HMAC 只证明消息由持有 Secret 的一方生成，并保护消息完整性。它不会加密内容；canonical string、设备 ID 和 signature 仍可能在链路上可见。真实公网连接还需要评估 TLS。

## 22.4 时间戳和 nonce 解决什么问题

很多平台会把 timestamp 或 nonce 放进签名。它们主要用于限制旧签名被重复使用。

设备若签名：

```text
clientId=zet6-01&timestamp=1700000000&nonce=4f8c...
```

平台可以检查 timestamp 是否在允许时间窗口内，并拒绝已经使用过或不符合规则的 nonce。具体窗口大小和 nonce 要求由平台决定。

F103 自己没有网络时间来源。设备必须明确时间从哪里来，例如：

- 外部 RTC；
- WiFi 模块提供的 SNTP/NTP；
- 受控配网阶段写入时间；
- 平台协议允许的其他时间同步机制。

如果时间未知，依赖绝对时间戳的签名和证书有效期检查都可能失败。不要在启动代码里随便填一个 Unix 时间让认证“先跑起来”。

## 22.5 配置文件和 Secret 分开管理

仓库可以提交模板：

```c
/* device_config.example.h */
#define DEVICE_PRODUCT_ID  "replace-me"
#define DEVICE_NAME        "replace-me"
#define DEVICE_CONFIG_VERSION 1U
```

真实配置放在被 Git 忽略的文件中：

```c
/* device_config.h */
#define DEVICE_PRODUCT_ID  "demo-product"
#define DEVICE_NAME        "room-01"
#define DEVICE_SECRET      "local-only-secret"
#define DEVICE_CONFIG_VERSION 1U
```

`.gitignore` 至少加入：

```text
device_config.h
wifi_credentials.h
```

如果 Secret 已经提交进 Git，再从最新文件中删除并不等于泄露已经消失。旧 commit 仍可能保留它，这时应撤销旧凭据并重新签发，而不是只做一次“清理历史”。

量产设备也不应该共用同一个 Device Secret。更合理的流程是每台设备拥有独立身份和密钥，并在生产或受控配置阶段写入。

## 22.6 给身份配置定义明确接口

业务代码不要到处直接引用宏。可以把身份和 Secret 统一暴露成结构体：

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

启动时只打印非敏感信息：

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

不要打印 Secret、完整 Authorization、包含 Secret 的 AT 命令，也不要把完整签名输入和 Secret 同时写进日志。

## 22.7 先做离线测试向量

接云平台之前，先在 PC 和 MCU 上对同一组公开演示数据计算 HMAC。这样可以把“密码学输入是否一致”和“网络认证是否成功”分开。

例如 PC 上：

```python
import hmac
import hashlib

message = b"clientId=zet6-01&timestamp=1700000000"
secret = b"demo-secret-not-for-production"

print(hmac.new(secret, message, hashlib.sha256).hexdigest())
```

把输出保存成测试向量：

```text
algorithm: HMAC-SHA256
message length: ...
message hex: ...
secret: demo-secret-not-for-production
expected hmac hex: ...
```

STM32 使用同样的公开 Secret 和同样的 message 字节计算。两边不一致时，先比较 message 的长度和逐字节十六进制，再检查算法和输出编码。

测试至少覆盖：

- 正常 ASCII 输入；
- 空字符串字段；
- 含 UTF-8 字符的字段；
- 只改变一个字符后的 HMAC；
- 输出十六进制大小写或 Base64 规则。

真实 Secret 不参与这些可提交的测试向量。

## 22.8 上云连接的状态顺序

认证逻辑进入网络任务以后，顺序可以写成：

```text
LOAD_CONFIG
    ↓
GET_TIME / PREPARE_NONCE
    ↓
BUILD_CANONICAL
    ↓
CALCULATE_SIGNATURE
    ↓
TCP/TLS CONNECT
    ↓
MQTT CONNECT WITH AUTH
    ↓
CONNACK
    ↓
ONLINE
```

每个阶段都要有独立错误码。`Cloud_BuildCanonical()` 失败和 Broker 拒绝认证是两种问题；TLS 握手失败也不应该统一归成“MQTT 连接失败”。

认证失败时不要高速无限重试。如果平台返回“凭据错误”“设备被禁用”这类稳定错误，继续每秒重连不会自行恢复，还会制造大量日志和流量。网络波动可以进入退避；配置错误则应进入等待人工处理或受控重新配置状态。

## 22.9 TLS 由谁负责要先确定

STM32F103ZET6 有 64 KB SRAM，本书又通过 AT 模块联网。真实云平台是否可接，首先取决于 TLS 放在哪里。

常见方案有三种：

- **无线模块负责 TLS**：模块必须支持目标 TLS 版本、SNI、证书验证、服务器名和对应错误码。
- **MCU 负责 HMAC，模块负责 TLS**：F103 只生成认证字段，TLS 会话仍在模块里完成。
- **隔离局域网明文实验**：只用于教学和公开演示数据，不当作真实公网安全方案。

如果模块只支持“能建立 TLS socket”但无法正确校验证书，仍然不能把它当成完整的服务器身份验证。需要查模块固件手册并实测证书加载、服务器名校验和失败路径。

不要用“连通一次”判断 TLS 方案可用。至少记录模块固件版本、握手错误码、证书配置方法、峰值供电情况和断线恢复行为。

## 22.10 数据模型继续沿用前面的字段

云平台 Payload 不需要重新发明一套温度单位。可以继续使用前面章节的定点数据，在 JSON 边界再转换成需要的表示：

```json
{
  "device": "room-01",
  "seq": 42,
  "temperature_centi": 2460,
  "humidity_permille": 580,
  "battery_mv": 3920
}
```

字段名、单位和无效值规则固定下来后，MQTT、HTTP 和本地日志都可以复用。同一个物理量不要在不同章节分别叫 `temp`、`temperature`、`t`，也不要一处用摄氏度浮点、一处用摄氏度百分之一整数却没有说明。

平台如果要求特定数据模型，再在云适配层做转换，不要反向修改传感器驱动的内部数据结构。

## 22.11 密钥有完整生命周期

Secret 需要考虑创建、写入、使用、轮换、吊销和退役。至少把这些状态记录清楚：

- 设备 ID；
- 固件版本；
- 配置版本；
- 当前凭据是否有效；
- 平台是否已吊销旧凭据。

F103 的读保护和封装可以增加读取难度，但不应被描述成硬件安全根。高价值设备要根据威胁模型评估安全芯片、受保护烧录、调试口策略和平台侧最小权限。

设备丢失或 Secret 泄露后，正确动作是平台侧吊销旧身份并配置新凭据。旧 Secret 不应长期留作“备用密码”。

## 22.12 排错顺序

云端认证失败时按这个顺序查：

1. 用公开测试向量确认 MCU 的 HMAC 实现与 PC 一致。
2. 比较 canonical string 的长度和逐字节内容。
3. 核对字段顺序、大小写、UTF-8、百分号编码、Hex/Base64 规则。
4. 检查 timestamp、nonce、Client ID、设备 ID 和配置版本。
5. 查看 MQTT CONNACK、HTTP 状态码或平台认证错误码。
6. 最后再查 TLS、证书、DNS、模块固件和网络。

如果第 2 步字节已经不同，继续换 Secret 或重试网络没有意义。先把签名输入统一。

## 22.13 练习

1. 提交一份 `device_config.example.h`，并确认真实 `device_config.h` 被 Git 忽略。
2. 选择一组公开 HMAC-SHA256 测试向量，在 PC 和 STM32 上得到相同结果。
3. 故意改变 canonical string 中一个字符，比较 HMAC 输出。
4. 模拟时间未同步，确认认证状态机不会继续使用伪造 timestamp 连接平台。
5. 模拟平台返回“凭据无效”，让网络任务停止快速重试并留下明确错误状态。
6. 给配置增加 `config_version`，启动日志只打印设备 ID、配置版本和 Secret 长度。

完成这一章后，设备接云平台时应能把失败明确定位到配置、时间、canonical string、HMAC、TLS 或 Broker 认证中的某一层，而不是统一显示一个“连接失败”。

> **上一章**：[第 21 章 · MQTT](./21-chapter.md)
>
> **下一章**：[第 23 章 · HTTP、响应解析与 cJSON](./23-chapter.md)
