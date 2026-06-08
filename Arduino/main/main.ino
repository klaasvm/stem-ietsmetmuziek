// Pins voor de 5 stappenmotoren (stap-pins)
const int STEP_PINS[5] = {13, 11, 10, 9, 8};
const int DIR_PIN_1 = 12;

// Arrays om de status en timing per motor bij te houden
unsigned long halfPeriod[5] = {0, 0, 0, 0, 0}; 
unsigned long lastToggle[5] = {0, 0, 0, 0, 0}; 
bool pinState[5] = {LOW, LOW, LOW, LOW, LOW};  

// Variabelen voor de 'delay' (non-blocking)
unsigned long waitStartTime = 0;
unsigned long waitDuration = 0;
bool waitingForTime = false;

// Variabelen voor het inlezen van Serial data
const byte numChars = 32;
char receivedChars[numChars];
boolean newData = false;

void setup() {
    Serial.begin(115200); 
    
    // Zet alle step-pins als output EN zorg dat ze uit staan
    for (int i = 0; i < 5; i++) {
        pinMode(STEP_PINS[i], OUTPUT);
        digitalWrite(STEP_PINS[i], LOW);
    }
    
    pinMode(DIR_PIN_1, OUTPUT);
    digitalWrite(DIR_PIN_1, HIGH); // Richting instellen
}

void loop() {
    unsigned long currentMicros = micros();

    // ---------------------------------------------------------
    // 1. MOTOREN AANSTUREN (Software PWM - Blokkeert nooit!)
    // ---------------------------------------------------------
    for (int i = 0; i < 5; i++) {
        if (halfPeriod[i] > 0) {
            // Check of het tijd is om de pin om te klappen
            if (currentMicros - lastToggle[i] >= halfPeriod[i]) {
                lastToggle[i] += halfPeriod[i]; 
                pinState[i] = !pinState[i];     
                digitalWrite(STEP_PINS[i], pinState[i]);
            }
        }
    }

    // ---------------------------------------------------------
    // 2. TIMING / PAUZES BEHEREN
    // ---------------------------------------------------------
    if (waitingForTime) {
        // Zodra de tijd verstreken is, sturen we "OK" terug naar de laptop
        if (millis() - waitStartTime >= waitDuration) {
            waitingForTime = false;
            Serial.println("OK"); 
        }
    } 
    // ---------------------------------------------------------
    // 3. NIEUWE DATA INLEZEN (Alleen als we niet wachten op een noot)
    // ---------------------------------------------------------
    else {
        recvWithEndMarker(); 
        if (newData) {
            parseData();
            newData = false;
        }
    }
}

// Functie om data veilig karakter voor karakter te lezen
void recvWithEndMarker() {
    static byte ndx = 0;
    char endMarker = '\n';
    char rc;

    while (Serial.available() > 0 && newData == false) {
        rc = Serial.read();

        if (rc != endMarker) {
            if (rc != '\r') { 
                receivedChars[ndx] = rc;
                ndx++;
                if (ndx >= numChars) {
                    ndx = numChars - 1; // Voorkom buffer overflow!
                }
            }
        }
        else {
            receivedChars[ndx] = '\0'; // Sluit de string af
            ndx = 0;
            newData = true;
        }
    }
}

// Functie om de format "motor,freq,duration" uit elkaar te halen
void parseData() {
    char * strtokIndx; 

    // 1e waarde: Motor ID
    strtokIndx = strtok(receivedChars, ",");
    if (strtokIndx == NULL) return;
    int motor = atoi(strtokIndx);

    // 2e waarde: Frequentie
    strtokIndx = strtok(NULL, ",");
    if (strtokIndx == NULL) return;
    long freq = atol(strtokIndx);

    // 3e waarde: Duration
    strtokIndx = strtok(NULL, ",");
    if (strtokIndx == NULL) return;
    long duration = atol(strtokIndx);

    // Pas de juiste motor aan (0 t/m 4)
    if (motor >= 0 && motor < 5) {
        if (freq > 0) {
            halfPeriod[motor] = 1000000UL / (2 * freq);
            lastToggle[motor] = micros(); 
        } else {
            halfPeriod[motor] = 0; 
            digitalWrite(STEP_PINS[motor], LOW); // Zorg dat coil niet onder stroom blijft
        }
    }

    // Wachttijd afhandelen
    if (duration > 0) {
        waitStartTime = millis();
        waitDuration = duration;
        waitingForTime = true;
    } else {
        // Bij 0 milliseconden direct een OK sturen (perfect voor akkoorden)
        Serial.println("OK");
    }
}