#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <PubSubClient.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <MPU6050.h>
#include "MAX30100_PulseOximeter.h"
#include "esp_task_wdt.h"

#define WDT_TIMEOUT_S 10

// ================== WIFI ==================
const char* WIFI_SSID     = "YOUR_WIFI";
const char* WIFI_PASSWORD = "YOUR_PASSWORD";

// ================== HIVEMQ CLOUD ==================
const char* MQTT_HOST = "================";
const int   MQTT_PORT = 8883; // TLS bắt buộc trên HiveMQ Cloud
const char* MQTT_USER = "YOUR_USERNAME";
const char* MQTT_PASS = "YOUR_PASSWORD";

const char* MQTT_CLIENT_ID   = "esp32-falldetect-01";
const char* TOPIC_DATA       = "falldetect/PROJECT/data";
const char* TOPIC_ALERT      = "falldetect/PROJECT/alert";
const char* TOPIC_SOS_CANCEL = "falldetect/PROJECT/sos_cancel";

WiFiClientSecure espClient;
PubSubClient mqttClient(espClient);

unsigned long lastMqttPublish = 0;
#define MQTT_PUBLISH_INTERVAL 2000

// ================== CẤU HÌNH TELEGRAM BOT ==================
// <<< ĐIỀN token bot lấy từ BotFather (nhớ Revoke token cũ nếu đã public ở đâu đó)
const char* TELEGRAM_BOT_TOKEN = "YOUR_BOT_TOKEN";
// <<< ĐIỀN chat_id bạn lấy từ bước getUpdates
const char* TELEGRAM_CHAT_ID   = "YOUR_CHAT_ID";

// Gửi tin nhắn cảnh báo qua Telegram
extern float heartRate;
extern float spO2;
void sendTelegramAlert(String reason) {
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("!!! Khong gui duoc Telegram: WiFi mat ket noi");
    return;
  }

  WiFiClientSecure tgClient;
  tgClient.setInsecure(); // bỏ qua kiểm tra chứng chỉ SSL cho gọn (đủ dùng cho đồ án)

  HTTPClient https;
  String url = "https://api.telegram.org/bot" + String(TELEGRAM_BOT_TOKEN) + "/sendMessage";

  String text = "⚠️ CANH BAO TE NGA!\n";
  text += "Ly do: " + reason + "\n";
  text += "Nhip tim: " + String((int)heartRate) + " bpm\n";
  text += "SpO2: " + String((int)spO2) + " %";

  // URL-encode khoảng trắng và ký tự đặc biệt cơ bản
  text.replace(" ", "%20");
  text.replace("\n", "%0A");
  text.replace("!", "%21");

  String fullUrl = url + "?chat_id=" + String(TELEGRAM_CHAT_ID) + "&text=" + text;

  if (https.begin(tgClient, fullUrl)) {
    int httpCode = https.GET();
    if (httpCode > 0) {
      Serial.println(">>> Telegram gui thanh cong, HTTP code: " + String(httpCode));
    } else {
      Serial.println("!!! Telegram gui that bai: " + https.errorToString(httpCode));
    }
    https.end();
  } else {
    Serial.println("!!! Khong the ket noi toi Telegram API");
  }
}

// ===== OLED =====
#define SCREEN_WIDTH 128
#define SCREEN_HEIGHT 64
#define OLED_RESET -1
Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, OLED_RESET);

// ===== MPU6050 =====
MPU6050 mpu;

// ===== MAX30100 =====
PulseOximeter pox;
#define REPORTING_PERIOD_MS 1000
uint32_t tsLastReport = 0;

// ===== CHÂN GPIO =====
#define PIN_BUZZER  25
#define PIN_LED     18
#define PIN_SOS     14

// ===== BIẾN SINH HIỆU =====
float heartRate = 0;
float spO2      = 0;
int16_t ax, ay, az, gx, gy, gz;

// ===== BỘ LỌC MOVING AVERAGE =====
#define FILTER_SIZE 10
float atotalBuffer[FILTER_SIZE];
int filterIndex = 0;

float movingAverage(float newVal) {
  atotalBuffer[filterIndex] = newVal;
  filterIndex = (filterIndex + 1) % FILTER_SIZE;
  float sum = 0;
  for (int i = 0; i < FILTER_SIZE; i++) sum += atotalBuffer[i];
  return sum / FILTER_SIZE;
}

void primeMovingAverage(float val) {
  for (int i = 0; i < FILTER_SIZE; i++) atotalBuffer[i] = val;
}

// ===== BIẾN COMPLEMENTARY FILTER =====
float cfRoll  = 0;
float cfPitch = 0;
unsigned long lastTime = 0;

// ===== BIẾN JERK (đạo hàm gia tốc) =====
float AtotalPrev = 1.0;
#define JERK_THRESHOLD 15.0

// ===== BIẾN THUẬT TOÁN TÉ NGÃ =====
bool freeFallDetected = false;
bool impactDetected   = false;
bool fallConfirmed    = false;

unsigned long freeFallStartTime = 0;
unsigned long impactStartTime   = 0;
unsigned long fallTime          = 0;

#define FREEFALL_THRESHOLD  0.4
#define FREEFALL_DURATION   80
#define IMPACT_THRESHOLD    2.5
#define IMPACT_WINDOW       500
#define CONFIRM_TIMER       10000UL

// ===== BIẾN SOS =====
volatile bool sosPressed = false;
volatile unsigned long lastSosTime = 0;
unsigned long lastOLEDUpdate = 0;
#define OLED_UPDATE_INTERVAL 200

// ===== CALLBACK MAX30100 =====
void onBeatDetected() {
  Serial.println(">>> Beat!");
}

void IRAM_ATTR sosISR() {
  unsigned long currentTime = millis();
  if (currentTime - lastSosTime > 500) {
    sosPressed = true;
    lastSosTime = currentTime;
  }
}

// ===== HÀM SAFE DELAY (giữ MQTT + pulse ox + WDT sống trong lúc chờ) =====
void safeDelay(unsigned long ms) {
  unsigned long start = millis();
  while (millis() - start < ms) {
    pox.update();
    mqttClient.loop();
    esp_task_wdt_reset();
  }
}

// ================== WIFI CONNECT ==================
void connectWiFi() {
  Serial.print("Dang ket noi WiFi");
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

  unsigned long startAttempt = millis();
  while (WiFi.status() != WL_CONNECTED) {
    Serial.print(".");
    delay(300);
    esp_task_wdt_reset();
    if (millis() - startAttempt > 20000) {
      Serial.println("\nWiFi that bai, khoi dong lai...");
      ESP.restart();
    }
  }
  Serial.println("\nWiFi OK! IP: " + WiFi.localIP().toString());
}

// ================== MQTT CALLBACK (nhận lệnh từ xa) ==================
void resetFall(); // forward declaration

void mqttCallback(char* topic, byte* payload, unsigned int length) {
  String msg;
  for (unsigned int i = 0; i < length; i++) msg += (char)payload[i];
  Serial.println("MQTT nhan [" + String(topic) + "]: " + msg);

  if (String(topic) == TOPIC_SOS_CANCEL && msg == "cancel") {
    resetFall();
    Serial.println(">>> SOS da duoc huy tu xa!");
  }
}

// ================== MQTT RECONNECT ==================
void reconnectMQTT() {
  if (mqttClient.connected()) return;

  Serial.print("Dang ket noi MQTT HiveMQ...");
  if (mqttClient.connect(MQTT_CLIENT_ID, MQTT_USER, MQTT_PASS)) {
    Serial.println(" OK!");
    mqttClient.subscribe(TOPIC_SOS_CANCEL);
  } else {
    Serial.print(" that bai, rc=");
    Serial.println(mqttClient.state());
  }
}

// ================== PUBLISH DỮ LIỆU ==================
void publishData(float Atotal, float jerk, String status) {
  if (!mqttClient.connected()) return;

  String payload = "{";
  payload += "\"heartRate\":" + String((int)heartRate) + ",";
  payload += "\"spO2\":" + String((int)spO2) + ",";
  payload += "\"atotal\":" + String(Atotal, 2) + ",";
  payload += "\"jerk\":" + String(jerk, 1) + ",";
  payload += "\"tilt\":" + String(sqrt(cfRoll*cfRoll + cfPitch*cfPitch), 1) + ",";
  payload += "\"fallConfirmed\":" + String(fallConfirmed ? "true" : "false") + ",";
  payload += "\"status\":\"" + status + "\"";
  payload += "}";

  bool ok = mqttClient.publish(TOPIC_DATA, payload.c_str());
  if (!ok) {
    Serial.println("!!! Publish data that bai (kiem tra buffer size / ket noi)");
  }
}

// ===== HÀM RESET FALL =====
void resetFall() {
  fallConfirmed     = false;
  freeFallDetected  = false;
  impactDetected    = false;
  freeFallStartTime = 0;
  impactStartTime   = 0;
  fallTime          = 0;
  digitalWrite(PIN_BUZZER, LOW);
  digitalWrite(PIN_LED,    LOW);
}

// ===== HÀM CẢNH BÁO =====
void triggerAlert(String reason) {
  Serial.println("!!! CANH BAO: " + reason);

  if (mqttClient.connected()) {
    String payload = "{\"alert\":true,\"reason\":\"" + reason + "\"}";
    bool ok = mqttClient.publish(TOPIC_ALERT, payload.c_str());
    if (!ok) Serial.println("!!! Publish alert that bai");
  }

  // Gửi cảnh báo qua Telegram
  sendTelegramAlert(reason);

  int beepCount    = 0;
  bool buzzerState = false;
  unsigned long lastBeep = millis();

  while (beepCount < 3) {
    pox.update();
    mqttClient.loop();
    esp_task_wdt_reset();
    if (millis() - lastBeep > 150) {
      buzzerState = !buzzerState;
      digitalWrite(PIN_BUZZER, buzzerState);
      digitalWrite(PIN_LED,    buzzerState);
      lastBeep = millis();
      if (!buzzerState) beepCount++;
    }
  }
  digitalWrite(PIN_BUZZER, LOW);
  digitalWrite(PIN_LED,    LOW);
}

// ===== HÀM OLED =====
void updateOLED(float Atotal, String status) {
  display.clearDisplay();
  display.setTextSize(1);
  display.setCursor(0, 0);
  display.print("== FALL DETECT ==");
  display.println(mqttClient.connected() ? " [MQTT]" : "");

  display.setCursor(0, 14);
  display.print("HR:");
  display.print((int)heartRate);
  display.print("bpm SpO2:");
  display.print((int)spO2);
  display.println("%");

  display.setCursor(0, 28);
  display.print("Atotal: ");
  display.print(Atotal, 2);
  display.println(" g");

  display.setCursor(0, 42);
  display.print("Status: ");
  display.println(status);

  display.display();
}

// ===== SETUP =====
void setup() {
  esp_task_wdt_config_t wdt_config = {
    .timeout_ms = WDT_TIMEOUT_S * 1000,
    .idle_core_mask = (1 << portNUM_PROCESSORS) - 1,
    .trigger_panic = true
  };
  esp_task_wdt_init(&wdt_config);
  esp_task_wdt_add(NULL);

  Serial.begin(115200);
  Wire.begin(21, 22);
  delay(50);

  pinMode(PIN_BUZZER, OUTPUT);
  pinMode(PIN_LED,    OUTPUT);
  pinMode(PIN_SOS,    INPUT_PULLUP);
  attachInterrupt(digitalPinToInterrupt(PIN_SOS), sosISR, FALLING);

  digitalWrite(PIN_BUZZER, LOW);
  digitalWrite(PIN_LED,    LOW);

  if (!display.begin(SSD1306_SWITCHCAPVCC, 0x3C)) {
    Serial.println("OLED LOI!");
    display.clearDisplay();
    while (true) {
      esp_task_wdt_reset();
      delay(100);
    }
  }
  display.clearDisplay();
  display.setTextSize(1);
  display.setTextColor(WHITE);
  display.setCursor(0, 0);
  display.println("Khoi dong...");
  display.display();
  delay(500);

  connectWiFi();

  espClient.setInsecure();

  mqttClient.setServer(MQTT_HOST, MQTT_PORT);
  mqttClient.setBufferSize(256);
  mqttClient.setCallback(mqttCallback);
  reconnectMQTT();

  mpu.initialize();
  if (!mpu.testConnection()) {
    Serial.println("MPU6050 LOI!");
    display.clearDisplay();
    display.setCursor(0, 0);
    display.println("MPU6050 LOI!");
    display.display();
    while (true) {
      esp_task_wdt_reset();
      delay(100);
    }
  }
  Serial.println("MPU6050 OK!");

  if (!pox.begin()) {
    Serial.println("MAX30100 LOI!");
    display.clearDisplay();
    display.setCursor(0, 0);
    display.println("MAX30100 LOI!");
    display.display();
    while (true) {
      esp_task_wdt_reset();
      delay(100);
    }
  }
  pox.setIRLedCurrent(MAX30100_LED_CURR_50MA);
  pox.setOnBeatDetectedCallback(onBeatDetected);
  Serial.println("MAX30100 OK!");

  digitalWrite(PIN_LED,    HIGH);
  digitalWrite(PIN_BUZZER, HIGH);
  safeDelay(200);
  digitalWrite(PIN_LED,    LOW);
  digitalWrite(PIN_BUZZER, LOW);

  lastTime = millis();

  {
    int16_t ax0, ay0, az0, gx0, gy0, gz0;
    mpu.getMotion6(&ax0, &ay0, &az0, &gx0, &gy0, &gz0);
    float A0 = sqrt(pow(ax0 / 16384.0, 2) + pow(ay0 / 16384.0, 2) + pow(az0 / 16384.0, 2));
    primeMovingAverage(A0);
    AtotalPrev = A0;
  }

  display.clearDisplay();
  display.setCursor(0, 0);
  display.println("=== SAN SANG ===");
  display.display();
  Serial.println("=== HE THONG SAN SANG ===");
}

// ===== LOOP =====
void loop() {
  esp_task_wdt_reset();

  pox.update();

  if (WiFi.status() != WL_CONNECTED) {
    connectWiFi();
  }
  if (!mqttClient.connected()) {
    reconnectMQTT();
  }
  mqttClient.loop();

  mpu.getMotion6(&ax, &ay, &az, &gx, &gy, &gz);
  float Ax = ax / 16384.0;
  float Ay = ay / 16384.0;
  float Az = az / 16384.0;
  float Gx = gx / 131.0;
  float Gy = gy / 131.0;

  float AtotalRaw = sqrt(Ax*Ax + Ay*Ay + Az*Az);
  float Atotal    = movingAverage(AtotalRaw);

  unsigned long now = millis();
  float dt = (now - lastTime) / 1000.0;
  if (dt > 0.05) dt = 0.05;
  if (dt <= 0)   dt = 0.001;
  lastTime = now;

  float accRoll  = atan2(Ay, Az) * 180.0 / PI;
  float accPitch = atan2(-Ax, sqrt(Ay*Ay + Az*Az)) * 180.0 / PI;

  cfRoll  = 0.96 * (cfRoll  + Gx * dt) + 0.04 * accRoll;
  cfPitch = 0.96 * (cfPitch + Gy * dt) + 0.04 * accPitch;

  float tilt = sqrt(cfRoll*cfRoll + cfPitch*cfPitch);

  float jerk = fabs(Atotal - AtotalPrev) / dt;
  AtotalPrev = Atotal;

  if (millis() - tsLastReport > REPORTING_PERIOD_MS) {
    heartRate    = pox.getHeartRate();
    spO2         = pox.getSpO2();
    tsLastReport = millis();
    Serial.print("HR: ");          Serial.print(heartRate);
    Serial.print(" | SpO2: ");     Serial.print(spO2);
    Serial.print(" | Raw: ");      Serial.print(AtotalRaw, 2);
    Serial.print(" | Filtered: "); Serial.print(Atotal, 2);
    Serial.print(" | Jerk: ");     Serial.print(jerk, 1);
    Serial.print(" | Tilt: ");     Serial.println(tilt, 1);
  }

  String status = "Binh thuong";

  // Giai đoạn 1 — Rơi tự do
  if (!freeFallDetected && !impactDetected && !fallConfirmed) {
    if (Atotal < FREEFALL_THRESHOLD) {
      if (freeFallStartTime == 0) {
        freeFallStartTime = millis();
      } else if (millis() - freeFallStartTime >= FREEFALL_DURATION) {
        freeFallDetected = true;
        impactStartTime  = millis();
        Serial.println(">>> GD1: Roi tu do!");
      }
    } else {
      freeFallStartTime = 0;
    }
  }

  // Giai đoạn 2 — Va chạm
  if (freeFallDetected && !impactDetected && !fallConfirmed) {
    if (millis() - impactStartTime > IMPACT_WINDOW) {
      Serial.println(">>> Reset: Khong co va cham");
      freeFallDetected  = false;
      freeFallStartTime = 0;
    } else if (Atotal > IMPACT_THRESHOLD && jerk > JERK_THRESHOLD) {
      impactDetected = true;
      fallConfirmed  = true;
      fallTime       = millis();
      Serial.println(">>> GD2: Va cham that! (Atotal + Jerk vuot nguong) -> TE NGA XAC NHAN (GD3 da bo)");
    }
  }

  // ===== Đếm ngược trước khi tự động gửi cảnh báo =====
  if (fallConfirmed) {
    unsigned long elapsed = millis() - fallTime;

    if (elapsed >= CONFIRM_TIMER) {
      triggerAlert("Te nga - Khong phan hoi!");
      status = "DA GUI CANH BAO!";
      resetFall();
    } else {
      int countdown = (CONFIRM_TIMER - elapsed) / 1000;
      status = "SOS sau: " + String(countdown) + "s";
      digitalWrite(PIN_LED,    (millis() / 500) % 2);
      digitalWrite(PIN_BUZZER, (millis() / 1000) % 2);
    }
  }

  // Nút SOS
  if (sosPressed) {
    sosPressed = false;
    if (fallConfirmed || impactDetected) {
      Serial.println(">>> Nguoi dung OK! Huy canh bao!");
      resetFall();
      digitalWrite(PIN_BUZZER, HIGH);
      safeDelay(100);
      digitalWrite(PIN_BUZZER, LOW);
      status = "Da huy canh bao";
      updateOLED(Atotal, status);
      safeDelay(1500);
    } else {
      Serial.println("!!! SOS CHU DONG!");
      triggerAlert("SOS chu dong!");
      status = "SOS!";
    }
  }

  // Gửi dữ liệu định kỳ lên MQTT (không chặn vòng lặp)
  if (millis() - lastMqttPublish >= MQTT_PUBLISH_INTERVAL) {
    lastMqttPublish = millis();
    publishData(Atotal, jerk, status);
  }

  if (millis() - lastOLEDUpdate >= OLED_UPDATE_INTERVAL) {
    lastOLEDUpdate = millis();
    updateOLED(Atotal, status);
  }
}
