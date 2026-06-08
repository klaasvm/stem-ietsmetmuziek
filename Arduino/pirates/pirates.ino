// Pins voor de 5 stappenmotoren
const int STEP_PINS[5] = {13, 11, 10, 9, 8};
const int DIR_PIN_1 = 12;

// Arrays om de status en timing per motor bij te houden
unsigned long halfPeriod[5] = {0, 0, 0, 0, 0}; 
unsigned long lastToggle[5] = {0, 0, 0, 0, 0}; 
bool pinState[5] = {LOW, LOW, LOW, LOW, LOW};  

// Variabelen voor de non-blocking delay
unsigned long waitStartTime = 0;
unsigned long waitDuration = 0;
bool waitingForTime = false;

struct Note {
    int motor;
    long freq;
    long duration;
};

// ---------------------------------------------------------
// HE'S A PIRATE - EXTENDED THEME (3-Stemmig: Melodie, Bas, Harmonie)
// Formaat: { Motor_ID, Frequentie_in_Hz, Duur_in_ms }
// ---------------------------------------------------------
const Note melody[] = {
    // --- INTRO ---
    {0, 220, 100}, {0, 0, 50}, // A3
    {0, 262, 100}, {0, 0, 50}, // C4

    // --- DEEL 1 ---
    // D-mineur akkoord (Bas: D3, Harmonie: A3, Melodie: D4)
    {2, 220, 0}, {1, 147, 0}, {0, 294, 250}, // Start 3 motoren tegelijk
    {2, 0, 0},   {1, 0, 0},   {0, 0, 50},    // Stop 3 motoren tegelijk
    {0, 294, 100}, {0, 0, 50},               // D4
    {0, 330, 100}, {0, 0, 50},               // E4

    // F-majeur akkoord (Bas: F3, Harmonie: C4, Melodie: F4)
    {2, 262, 0}, {1, 175, 0}, {0, 349, 250}, 
    {2, 0, 0},   {1, 0, 0},   {0, 0, 50},
    {0, 349, 100}, {0, 0, 50},               // F4
    {0, 392, 100}, {0, 0, 50},               // G4

    // E-mineur overgang (Bas: E3, Harmonie: B3, Melodie: E4)
    {2, 247, 0}, {1, 165, 0}, {0, 330, 250}, 
    {2, 0, 0},   {1, 0, 0},   {0, 0, 50},
    {0, 330, 100}, {0, 0, 50},               // E4
    {0, 294, 100}, {0, 0, 50},               // D4
    {0, 262, 100}, {0, 0, 50},               // C4

    // Terug naar D-mineur
    {2, 220, 0}, {1, 147, 0}, {0, 294, 400}, 
    {2, 0, 0},   {1, 0, 0},   {0, 0, 100},   // Lange pauze

    // --- DEEL 2 ---
    // Opbouw
    {0, 220, 100}, {0, 0, 50}, // A3
    {0, 262, 100}, {0, 0, 50}, // C4

    // D-mineur
    {2, 220, 0}, {1, 147, 0}, {0, 294, 250}, 
    {2, 0, 0},   {1, 0, 0},   {0, 0, 50},
    {0, 294, 100}, {0, 0, 50},               // D4
    {0, 349, 100}, {0, 0, 50},               // F4

    // G-mineur (Bas: G3, Harmonie: D4, Melodie: G4)
    {2, 294, 0}, {1, 196, 0}, {0, 392, 250}, 
    {2, 0, 0},   {1, 0, 0},   {0, 0, 50},
    {0, 392, 100}, {0, 0, 50},               // G4
    {0, 440, 100}, {0, 0, 50},               // A4

    // Bb-majeur (Bas: Bb3, Harmonie: D4, Melodie: Bb4)
    {2, 294, 0}, {1, 233, 0}, {0, 466, 250}, 
    {2, 0, 0},   {1, 0, 0},   {0, 0, 50},
    {0, 466, 100}, {0, 0, 50},               // Bb4
    {0, 440, 100}, {0, 0, 50},               // A4
    {0, 392, 100}, {0, 0, 50},               // G4

    // A-majeur naar D-mineur val
    {2, 277, 0}, {1, 220, 0}, {0, 440, 250}, // A-majeur akkoord
    {2, 0, 0},   {1, 0, 0},   {0, 0, 50},
    {2, 220, 0}, {1, 147, 0}, {0, 294, 300}, // BAM! D-mineur
    {2, 0, 0},   {1, 0, 0},   {0, 0, 100},

    // --- DEEL 3 ---
    {0, 294, 100}, {0, 0, 50},               // D4
    {0, 330, 100}, {0, 0, 50},               // E4

    // F-majeur
    {2, 262, 0}, {1, 175, 0}, {0, 349, 250}, 
    {2, 0, 0},   {1, 0, 0},   {0, 0, 50},
    {0, 349, 100}, {0, 0, 50},               // F4
    {0, 392, 100}, {0, 0, 50},               // G4

    // A-majeur
    {2, 277, 0}, {1, 220, 0}, {0, 440, 250}, 
    {2, 0, 0},   {1, 0, 0},   {0, 0, 50},
    {0, 294, 100}, {0, 0, 50},               // D4
    {0, 349, 100}, {0, 0, 50},               // F4

    // E-mineur opbouw naar het einde
    {2, 247, 0}, {1, 165, 0}, {0, 330, 250}, 
    {2, 0, 0},   {1, 0, 0},   {0, 0, 50},
    {0, 330, 100}, {0, 0, 50},               // E4
    {0, 349, 100}, {0, 0, 50},               // F4
    {0, 294, 100}, {0, 0, 50},               // D4

    // HET LAATSTE AKKOORD (E-mineur lang)
    {2, 247, 0}, {1, 165, 0}, {0, 330, 600}, // Laag en hard!
    {2, 0, 0},   {1, 0, 0},   {0, 0, 300}    // Stop en stilte
};

int currentNote = 0;
// De compiler berekent hier automatisch hoeveel regels er in de melody array staan!
int totalNotes = sizeof(melody) / sizeof(melody[0]);

void setup() {
    for (int i = 0; i < 5; i++) {
        pinMode(STEP_PINS[i], OUTPUT);
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
            if (currentMicros - lastToggle[i] >= halfPeriod[i]) {
                lastToggle[i] += halfPeriod[i]; 
                pinState[i] = !pinState[i];     
                digitalWrite(STEP_PINS[i], pinState[i]);
            }
        }
    }

    // ---------------------------------------------------------
    // 2. MUZIEK SEQUENCER (Lees de array uit)
    // ---------------------------------------------------------
    if (waitingForTime) {
        if (millis() - waitStartTime >= waitDuration) {
            waitingForTime = false;
        }
    } 
    else {
        if (currentNote < totalNotes) {
            playNote(melody[currentNote]);
            currentNote++;
        } else {
            // Liedje is klaar! Zet alles uit voor de zekerheid
            for(int i=0; i<5; i++) { 
                halfPeriod[i] = 0; 
                digitalWrite(STEP_PINS[i], LOW); 
            }
            
            // Wacht 3 seconden en begin dan weer opnieuw
            waitStartTime = millis();
            waitDuration = 3000;
            waitingForTime = true;
            currentNote = 0; 
        }
    }
}

// Functie die een instructie uit de array vertaalt naar motor-acties
void playNote(Note n) {
    if (n.motor >= 0 && n.motor < 5) {
        if (n.freq > 0) {
            halfPeriod[n.motor] = 1000000UL / (2 * n.freq);
            lastToggle[n.motor] = micros(); 
        } else {
            // Frequentie is 0, dus motor moet stil
            halfPeriod[n.motor] = 0;
            digitalWrite(STEP_PINS[n.motor], LOW);
        }
    }

    if (n.duration > 0) {
        waitStartTime = millis();
        waitDuration = n.duration;
        waitingForTime = true;
    }
}