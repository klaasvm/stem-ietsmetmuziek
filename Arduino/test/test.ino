<<<<<<< Updated upstream
const int STEP_PIN = 13;
const int DIR_PIN  = 12;
=======
// --- Instellingen ---
const int STEP_PIN_1 = 13;
const int STEP_PIN_2 = 11;
const int STEP_PIN_3 = 10;
const int DIR_PIN_1  = 12;
>>>>>>> Stashed changes
const int DELAY_US = 1500;
const int DIRECTION = 1;

void setup() {
<<<<<<< Updated upstream
    pinMode(STEP_PIN, OUTPUT);
    pinMode(DIR_PIN, OUTPUT);
    digitalWrite(DIR_PIN, 1); 

    
}

void loop() {
    digitalWrite(STEP_PIN, HIGH);
=======
  Serial.begin(9600);
  pinMode(STEP_PIN_1, OUTPUT);
  pinMode(STEP_PIN_2, OUTPUT);
  pinMode(STEP_PIN_3, OUTPUT);
  pinMode(DIR_PIN_1, OUTPUT);
  digitalWrite(DIR_PIN_1, 1); // Richting instellen

  // Print de status naar de Seriële Monitor
  Serial.println("Stepper motor test gestart");
  Serial.print("  STEP pin : "); Serial.println(STEP_PIN_1);
  Serial.print("  DIR  pin : "); Serial.println(DIR_PIN_1);
  Serial.print("  Richting : "); Serial.println(DIRECTION == 1 ? "vooruit" : "achteruit");
  Serial.print("  Delay    : "); Serial.print(DELAY_US); Serial.println(" us per stap");
  Serial.println("Typ 'start' om de motor te starten of 'stop' om te stoppen.");
}

void loop() {
  // 1. Controleren of er seriële data binnenkomt
  if (Serial.available() > 0) {
    String commando = Serial.readStringUntil('\n'); // Lees het bericht tot de enter
    commando.trim(); // Verwijder onzichtbare spaties of enters (\r)

    if (commando.equalsIgnoreCase("start")) {
      motorLoopt = true;
      Serial.println("Motor GESTART");
    } 
    else if (commando.equalsIgnoreCase("stop")) {
      motorLoopt = false;
      Serial.println("Motor GESTOPPT");
    }
  }

  // 2. De motor alleen laten draaien als 'motorLoopt' true is
  if (motorLoopt) {
    digitalWrite(STEP_PIN_1, HIGH);
    digitalWrite(STEP_PIN_2, HIGH);
    digitalWrite(STEP_PIN_3, HIGH);
>>>>>>> Stashed changes
    delayMicroseconds(DELAY_US / 2);
    digitalWrite(STEP_PIN_1, LOW);
    digitalWrite(STEP_PIN_2, LOW);
    digitalWrite(STEP_PIN_3, LOW);
    delayMicroseconds(DELAY_US / 2);
}