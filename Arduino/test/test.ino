// --- Instellingen ---
const int STEP_PIN = 13;
const int DIR_PIN  = 12;
const int DELAY_US = 1500;
const int DIRECTION = 1;

bool motorLoopt = true; // De motor begint in de 'aan' stand

void setup() {
  Serial.begin(9600);
  pinMode(STEP_PIN, OUTPUT);
  pinMode(DIR_PIN, OUTPUT);
  digitalWrite(DIR_PIN, 1); // Richting instellen

  // Print de status naar de Seriële Monitor
  Serial.println("Stepper motor test gestart");
  Serial.print("  STEP pin : "); Serial.println(STEP_PIN);
  Serial.print("  DIR  pin : "); Serial.println(DIR_PIN);
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
    digitalWrite(STEP_PIN, HIGH);
    delayMicroseconds(DELAY_US / 2);
    digitalWrite(STEP_PIN, LOW);
    delayMicroseconds(DELAY_US / 2);
  }
}
