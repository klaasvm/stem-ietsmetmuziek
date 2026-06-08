// Pins voor de 5 stappenmotoren (stap-pins)
const int STEP_PINS[5] = {13, 11, 10, 9, 8};
const int DIR_PIN_1 = 12;

// Arrays om de status en timing per motor bij te houden
unsigned long halfPeriod[5] = {0, 0, 0, 0, 0}; // Tijd tussen elke HIGH/LOW wissel (bepaalt de frequentie)
unsigned long lastToggle[5] = {0, 0, 0, 0, 0}; // Laatste keer dat de pin is omgeschakeld
bool pinState[5] = {LOW, LOW, LOW, LOW, LOW};  // Huidige status van de pin

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
    
    for (int i = 0; i < 5; i++) {
        pinMode(STEP_PINS[i], OUTPUT);
    }
    
    pinMode(DIR_PIN_1, OUTPUT);
    digitalWrite(DIR_PIN_1, HIGH); // Richting instellen
}

void loop() {
    unsigned long currentMicros = micros();

    // ---------------------------------------------------------
    // 1. MOTOREN AANSTUREN (Software PWM)
    // Dit stukje draait continu en mag nooit geblokkeerd worden
    // ---------------------------------------------------------
    for (int i = 0; i < 5; i++) {
        if (halfPeriod[i] > 0) {
            if (currentMicros - lastToggle[i] >= halfPeriod[i]) {
                lastToggle[i] += halfPeriod[i]; // Behoud perfecte timing
                pinState[i] = !pinState[i];     // Wissel HIGH naar LOW of andersom
                digitalWrite(STEP_PINS[i], pinState[i]);
            }
        }
    }

    // ---------------------------------------------------------
    // 2. TIMING / PAUZES BEHEREN (Vervanger voor delay)
    // ---------------------------------------------------------
    if (waitingForTime) {
        // Controleer of de gewenste wachttijd (duration) verstreken is
        if (millis() - waitStartTime >= waitDuration) {
            waitingForTime = false;
            Serial.println("OK"); // Geef laptop het sein voor de volgende noot
        }
    } 
    // ---------------------------------------------------------
    // 3. NIEUWE DATA INLEZEN (Als we niet aan het wachten zijn)
    // ---------------------------------------------------------
    else {
        recvWithEndMarker(); // Lees Serial in zonder de loop te pauzeren

        if (newData) {
            parseData();
            newData = false;
        }
    }
}

// Functie om data karakter voor karakter te lezen zonder de code te pauzeren
void recvWithEndMarker() {
    static byte ndx = 0;
    char endMarker = '\n';
    char rc;

    while (Serial.available() > 0 && newData == false) {
        rc = Serial.read();

        if (rc != endMarker) {
            if (rc != '\r') { // Negeer carriage returns
                receivedChars[ndx] = rc;
                ndx++;
                if (ndx >= numChars) {
                    ndx = numChars - 1;
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

// Functie om "0,440,240" uit elkaar te halen
void parseData() {
    char * strtokIndx; // Gebruikt voor het splitsen van de string

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

    // Pas de juiste motor aan
    if (motor >= 0 && motor < 5) {
        if (freq > 0) {
            // Bereken de tijd per 'halve golf' in microseconden
            halfPeriod[motor] = 1000000UL / (2 * freq);
            lastToggle[motor] = micros(); // Reset de timer voor deze specifieke motor
        } else {
            halfPeriod[motor] = 0; // Frequentie 0 = motor uit
            digitalWrite(STEP_PINS[motor], LOW);
        }
    }

    // Wachttijd afhandelen
    if (duration > 0) {
        waitStartTime = millis();
        waitDuration = duration;
        waitingForTime = true;
    } else {
        // Als duration 0 is, betekent dit dat de laptop nóg een actie op DIT exacte 
        // moment wil uitvoeren (bijv. voor akkoorden). We sturen direct "OK" terug.
        Serial.println("OK");
    }
}