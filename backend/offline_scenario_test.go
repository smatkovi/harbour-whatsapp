package main

import (
	"fmt"
	"testing"
	"time"
)

func oldDelay(n int) time.Duration {
	if n <= 0 {
		return 0
	}
	d := time.Duration(5*(1<<uint(n-1))) * time.Second
	if d > 5*time.Minute {
		d = 5 * time.Minute
	}
	return d
}

func newDelay(n int) time.Duration {
	if n <= 0 {
		return 0
	}
	if n > maxBackoffStep {
		n = maxBackoffStep
	}
	d := time.Duration(5*(1<<uint(n-1))) * time.Second
	if d > 5*time.Minute {
		d = 5 * time.Minute
	}
	return d
}

// Acht Stunden Flugmodus: wie oft klopft der Daemon an, und wie eng wird es?
func simulate(delay func(int) time.Duration, window time.Duration) (attempts int, minGap time.Duration) {
	const minInterval = 10 * time.Second
	var t time.Duration
	n := 0
	minGap = time.Hour
	last := time.Duration(-1)
	for t < window {
		n++
		d := delay(n)
		if d < minInterval {
			d = minInterval // Mindestabstand der Wache greift
		}
		t += d
		if t > window {
			break
		}
		attempts++
		// Erst NACH der Rampe messen: die ersten Versuche sollen bewusst
		// eng liegen (kurzer Aussetzer soll sofort geheilt werden)
		if n > maxBackoffStep && last >= 0 && t-last < minGap {
			minGap = t - last
		}
		last = t
	}
	return
}

func TestOfflineNightScenario(t *testing.T) {
	window := 8 * time.Hour
	oa, og := simulate(oldDelay, window)
	na, ng := simulate(newDelay, window)
	fmt.Printf("  acht Stunden ohne Netz\n")
	fmt.Printf("    alte Formel: %4d Versuche, engster Abstand %v\n", oa, og)
	fmt.Printf("    neue Formel: %4d Versuche, engster Abstand %v\n", na, ng)
	if ng < 5*time.Minute {
		t.Errorf("Dauerabstand faellt unter fuenf Minuten: %v", ng)
	}
	if og >= 5*time.Minute {
		t.Errorf("alte Formel haette hier gar kein Problem gehabt (%v) - Szenario prueft nichts", og)
	}
	if na > 100 {
		t.Errorf("zu viele Versuche in acht Stunden: %d", na)
	}
	if oa <= na {
		t.Logf("Hinweis: alte Formel war hier nicht schlechter (%d vs %d)", oa, na)
	}
}
