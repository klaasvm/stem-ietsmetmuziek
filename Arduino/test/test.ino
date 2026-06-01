const int STEP_PIN = 13;
const int DIR_PIN  = 12;
const int DELAY_US = 1500;
const int DIRECTION = 1;

void setup() {
    pinMode(STEP_PIN, OUTPUT);
    pinMode(DIR_PIN, OUTPUT);
    digitalWrite(DIR_PIN, 1); 

    
}

void loop() {
    digitalWrite(STEP_PIN, HIGH);
    delayMicroseconds(DELAY_US / 2);
    digitalWrite(STEP_PIN, LOW);
    delayMicroseconds(DELAY_US / 2);
}