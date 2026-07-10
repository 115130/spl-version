# 第 19 章 · 温度记录仪 BLE 版

> **本章产出**：用同一个 STM32 工程、同一块 DX-WF24，把第 18 章的 WiFi 发送换成 BLE 发送
>
> **变化**：只改 `WiFiTxTask` → `BLETxTask`，传感器/协议/缓冲区代码**一字不改**

---

## 19.1 BLE 版本 vs WiFi 版本

| | WiFi 版（第 18 章） | BLE 版（本章） |
|---|---|---|
| **通信方式** | TCP (AT+CIPSTART/CIPSEND) | BLE GATT (AT+BLEINIT/BLEGATTSEND) |
| **接收端** | PC 上的 C 网关 (gateway.c) | 手机 App（nRF Connect / LightBlue） |
| **需要 WiFi 路由器** | ✅ | ❌（手机直连） |
| **功耗** | 高 | 低 |
| **传感器代码** | 不变 | 不变 |
| **协议格式** | 不变（15 字节二进制包） | 不变 |

## 19.2 唯一需要改的：通信初始化

```c
/* WiFi 版（Ch18）*/
UART2_Init(115200);
WiFi_Init();                          /* AT + CWMODE + CWJAP + CIPSTART */

/* BLE 版（本章）*/
UART2_Init(115200);
BLE_Init();                           /* AT + BLEINIT + BLEGATTSSRV + BLEADVSTART */
```

### BLE_Init 函数

```c
uint8_t BLE_Init(void) {
    vTaskDelay(pdMS_TO_TICKS(1500));

    // 关 WiFi（如之前开过）
    AT_ClearRxBuf(); AT_SendCmd("AT+CWMODE=0");
    AT_WaitResponse("OK", 2000);

    // BLE GATT Server 初始化
    AT_ClearRxBuf(); AT_SendCmd("AT+BLEINIT=2");
    if (!AT_WaitResponse("OK", 3000)) return 0;

    // 创建服务 + 特征值
    AT_ClearRxBuf(); AT_SendCmd("AT+BLEGATTSSRV=1");
    AT_WaitResponse("OK", 2000);
    AT_ClearRxBuf(); AT_SendCmd("AT+BLEGATTSCHAR=1,0xFFE1,0x12,20");
    AT_WaitResponse("OK", 2000);

    // 广播
    AT_ClearRxBuf(); AT_SendCmd("AT+BLEADVNAME=\"TempLogger\"");
    AT_WaitResponse("OK", 2000);
    AT_ClearRxBuf(); AT_SendCmd("AT+BLEADVSTART");
    AT_WaitResponse("OK", 3000);

    printf("BLE 已广播，用手机 App 搜索 TempLogger\r\n");
    return 1;
}
```

## 19.3 BLE 发送

BLE 发送不像 WiFi 那样直接发二进制字节——大多数 BLE AT 固件要求数据转成 16 进制字符串：

```c
void BLE_SendPacket(const TempPacket *pkt) {
    char hex[32];
    // 将 15 字节的二进制包转为 30 字符的十六进制字符串
    for (int i = 0; i < 15; i++)
        sprintf(hex + i*2, "%02X", ((uint8_t*)pkt)[i]);

    char cmd[128];
    snprintf(cmd, sizeof(cmd), "AT+BLEGATTSEND=1,%s", hex);
    AT_ClearRxBuf(); AT_SendCmd(cmd);
    AT_WaitResponse("OK", 3000);
}
```

## 19.4 BLETxTask

```c
void BLETxTask(void *pv) {
    UART2_Init(115200);
    BLE_Init();

    while (1) {
        if (RingBuf_Count(&tx_ring) >= 256) {
            TempPacket batch[256];
            int n = 0;
            while (n < 256 && RingBuf_Pop(&tx_ring, &batch[n]) == 0)
                n++;
            for (int i = 0; i < n; i++) {
                BLE_SendPacket(&batch[i]);
                vTaskDelay(pdMS_TO_TICKS(200));
            }
        }
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
}
```

## 19.5 PC 端用什么收

PC 如果没有 BLE 硬件，可以用手机 App 收数据。Chrome 83+ 也支持 Web Bluetooth API：

```javascript
// 浏览器控制台即可
const device = await navigator.bluetooth.requestDevice({
    filters: [{ name: 'TempLogger' }]
});
const server = await device.gatt.connect();
const service = await server.getPrimaryService(0xFFE0);
const char = await service.getCharacteristic(0xFFE1);
char.addEventListener('characteristicvaluechanged', e => {
    const pkt = parse_temppacket(e.target.value);
    console.log(`温度: ${pkt.ntc/100}°C`);
});
char.startNotifications();
```

> 完整代码和 WiFi 版共用 `sensors/`、`ringbuf.c`、`protocol.c`。唯一区别是 `main.c` 中把 `WiFiTxTask` 换成 `BLETxTask`。

---

> **下一章**：[第 20 章 · TCP/IP 协议栈浅析](./20-chapter.md)
