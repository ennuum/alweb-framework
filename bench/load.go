// load — générateur de charge HTTP/1.1 minimal pour les bancs d'essai d'alweb.
//
//	go run bench/load.go -url http://127.0.0.1:8080/ -c 32 -d 10s
//	go run bench/load.go -url https://127.0.0.1:8443/ -k -new     # HTTPS, une connexion (poignée de main) par requête
//	go run bench/load.go -url https://127.0.0.1:8443/ -k -new -resume   # idem, sessions reprises par ticket
//
// c clients persistants (keep-alive) envoient des requêtes en boucle pendant d ; affiche le débit (req/s), les
// latences (p50, p90, p99, max) et le nombre d'erreurs. -k : certificat non vérifié (auto-signé) ; -new : sans
// keep-alive (mesure les poignées de main TLS). Bibliothèque standard Go uniquement.
package main

import (
	"crypto/tls"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"sync"
	"time"
)

func main() {
	url := flag.String("url", "http://127.0.0.1:8080/", "URL à charger")
	conc := flag.Int("c", 16, "clients simultanés")
	dur := flag.Duration("d", 10*time.Second, "durée")
	warm := flag.Duration("w", 1*time.Second, "chauffe (non comptée)")
	jsonOut := flag.Bool("json", false, "sortie JSON")
	insecure := flag.Bool("k", false, "HTTPS : certificat non vérifié")
	fresh := flag.Bool("new", false, "nouvelle connexion à chaque requête (sans keep-alive)")
	resume := flag.Bool("resume", false, "HTTPS : reprise de session TLS (tickets) entre les connexions")
	flag.Parse()
	var cache tls.ClientSessionCache
	if *resume {
		cache = tls.NewLRUClientSessionCache(256)
	}

	tr := &http.Transport{MaxIdleConns: *conc * 2, MaxIdleConnsPerHost: *conc * 2, DisableCompression: true,
		DisableKeepAlives: *fresh, TLSClientConfig: &tls.Config{InsecureSkipVerify: *insecure, ClientSessionCache: cache}}
	client := &http.Client{Transport: tr, Timeout: 30 * time.Second}

	var mu sync.Mutex
	var lat []time.Duration
	errs, bad := 0, 0
	start := time.Now()
	measureFrom := start.Add(*warm)
	end := measureFrom.Add(*dur)
	var wg sync.WaitGroup
	for i := 0; i < *conc; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			local := make([]time.Duration, 0, 4096)
			le, lb := 0, 0
			for {
				t0 := time.Now()
				if t0.After(end) {
					break
				}
				resp, err := client.Get(*url)
				if err != nil {
					if t0.After(measureFrom) {
						le++
					}
					time.Sleep(10 * time.Millisecond)
					continue
				}
				io.Copy(io.Discard, resp.Body)
				resp.Body.Close()
				if t0.After(measureFrom) {
					if resp.StatusCode >= 400 {
						lb++
					}
					local = append(local, time.Since(t0))
				}
			}
			mu.Lock()
			lat = append(lat, local...)
			errs += le
			bad += lb
			mu.Unlock()
		}()
	}
	wg.Wait()
	sort.Slice(lat, func(a, b int) bool { return lat[a] < lat[b] })
	pct := func(p float64) float64 {
		if len(lat) == 0 {
			return 0
		}
		i := int(p * float64(len(lat)-1))
		return float64(lat[i].Microseconds()) / 1000
	}
	rps := float64(len(lat)) / dur.Seconds()
	maxv := 0.0
	if len(lat) > 0 {
		maxv = float64(lat[len(lat)-1].Microseconds()) / 1000
	}
	if *jsonOut {
		fmt.Printf("{\"url\":%q,\"c\":%d,\"rps\":%.1f,\"p50_ms\":%.2f,\"p90_ms\":%.2f,\"p99_ms\":%.2f,\"max_ms\":%.2f,\"requests\":%d,\"errors\":%d,\"status_ge_400\":%d}\n",
			*url, *conc, rps, pct(0.5), pct(0.9), pct(0.99), maxv, len(lat), errs, bad)
	} else {
		fmt.Printf("%s  c=%d  %.0f req/s  p50 %.2f ms  p90 %.2f ms  p99 %.2f ms  max %.2f ms  (%d requêtes, %d erreurs, %d statuts >= 400)\n",
			*url, *conc, rps, pct(0.5), pct(0.9), pct(0.99), maxv, len(lat), errs, bad)
	}
	if errs > 0 {
		os.Exit(1)
	}
}
