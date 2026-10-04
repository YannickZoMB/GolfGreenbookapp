# Greenbook

iPhone-App, die ein Golfgrün mit dem LiDAR-Sensor scannt und daraus ein Greenbook erzeugt.

**Stand: Prototyp 0.1.** Grün scannen, Kante per Punkten setzen, Höhenkarte anzeigen (tief = rot, hoch = grün), Bild und Messwerte teilen. Pfeile, Höhenlinien, Einstellungen und das Buch für alle Löcher folgen, sobald die Messung auf einem echten Grün überzeugt.

Voraussetzungen: Mac mit Xcode, iPhone mit LiDAR (12 Pro oder neuer) und mindestens iOS 17.

## App im Simulator anschauen (ohne iPhone)

1. Öffne Xcode, wähle im Startfenster *Clone Git Repository …* und füge `https://github.com/YannickZoMB/GolfGreenbookapp` ein. Anschließend öffnet sich das Projekt `Greenbook.xcodeproj`.
2. Oben in der Mitte von Xcode als Ziel einen Simulator wählen, z. B. *iPhone 16 Pro*. Steht dort keiner zur Auswahl, bietet Xcode an, die iOS-Simulatoren herunterzuladen (*Get* bzw. *Settings → Components*).
3. Auf ▶︎ klicken. Nach dem Bauen erscheint ein iPhone-Fenster mit der App.
4. Tippe auf *Demo-Grün ansehen*: Du siehst ein erfundenes Beispielgrün mit Höhenkarte. Scannen geht im Simulator nicht, dafür braucht es das echte iPhone.

Den Code selbst siehst du links in der Seitenleiste im Ordner *Greenbook*.

## Erstes Aufspielen aufs iPhone

1. **Projekt holen:** wie oben beim Simulator beschrieben.
2. **Apple-ID hinterlegen:** Xcode → *Settings … → Accounts* → unten links „+“ → *Apple ID*, mit deiner Apple-ID anmelden.
3. **Signieren:** Links in der Seitenleiste ganz oben auf das blaue Projektsymbol *Greenbook* klicken → Target *Greenbook* → Reiter *Signing & Capabilities* → bei *Team* deinen Namen („Personal Team“) wählen.
   Meldet Xcode, die *Bundle Identifier* sei vergeben, ändere sie in etwas Eigenes, z. B. `de.deinname.greenbook`.
4. **iPhone verbinden:** iPhone per Kabel an den Mac, entsperren und „Diesem Computer vertrauen“ bestätigen.
5. **Entwicklermodus einschalten:** Auf dem iPhone *Einstellungen → Datenschutz & Sicherheit → Entwicklermodus* aktivieren und neu starten. (Der Schalter erscheint erst, nachdem das iPhone einmal mit Xcode verbunden war.)
6. **Starten:** Oben in Xcode dein iPhone als Ziel auswählen und auf ▶︎ klicken.
7. **Beim ersten Start** blockiert das iPhone die App. Dann: *Einstellungen → Allgemein → VPN & Geräteverwaltung* → deine Apple-ID → *Vertrauen*. Danach in Xcode erneut ▶︎.

Mit einem kostenlosen Account läuft die App 7 Tage; danach einfach in Xcode wieder ▶︎ drücken.

## So scannst du

1. *Neuen Scan starten*, kurz warten, bis der gelbe Hinweis oben verschwindet.
2. **Kante:** Lauf um das Grün und richte das Fadenkreuz auf die Grenze zwischen Grün und Vorgrün. Alle 2–3 m auf *Punkt setzen* tippen (die Anzeige zeigt den Abstand zum letzten Punkt). Falsch gesetzt? Pfeil-Knopf löscht den letzten Punkt.
3. **Fläche:** Geh danach in Bahnen über das Grün, das iPhone in Hüfthöhe schräg nach unten, ca. 1–3 m vor dir. Die kleine Karte unten links zeigt, was schon erfasst ist.
4. *Fertig* tippen: die App rechnet die Höhenkarte aus.
5. Über das Teilen-Symbol oben rechts kannst du das Bild und die Messwerte (CSV) verschicken, z. B. um die Genauigkeit gemeinsam auszuwerten.

## Aufbau des Codes

| Datei | Aufgabe |
| --- | --- |
| `ScanSession.swift` | AR-Sitzung, rechnet LiDAR-Tiefenbilder in Weltpunkte um |
| `HeightGrid.swift` | sammelt Punkte in einem 5-cm-Höhenraster |
| `EdgeSpline.swift` | verbindet Kantenpunkte zu einer geschwungenen Kurve |
| `GreenModel.swift` | Auswertung: Lücken füllen, glätten, Farbbild erzeugen, CSV-Export |
| `ScanView.swift` | Scan-Bildschirm mit Fadenkreuz und Mini-Karte |
| `ResultView.swift` | Ergebnis mit Höhenkarte, Legende, Maßstab, Teilen |
| `DemoGreen.swift` | erfundenes Beispielgrün zum Ausprobieren ohne Scan |
