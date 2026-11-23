package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	gnet "github.com/shirou/gopsutil/v4/net"
)

// ───────────────────────── domain ─────────────────────────

type Geo struct {
	IP       string `json:"ip"`
	City     string `json:"city"`
	Region   string `json:"region"`
	Country  string `json:"country"`
	Org      string `json:"org"`
	Timezone string `json:"timezone"`
	Loc      string `json:"loc"`
}

type WiFiInfo struct {
	SSID      string
	Band      string  // "5 GHz"
	Channel   int     // 36
	Standard  string  // "802.11ac"
	RxMbps    float64 // 433.3
	TxMbps    float64 // 433.3
	SignalPct int     // 96
}

type LANInfo struct {
	IP          string
	Gateway     string
	GatewayPing time.Duration
	GatewayOK   bool
	DNSServers  []string
}

type Service struct {
	Name, Host string
	DNSOK      bool
	DNSTime    time.Duration
	ResolvedIP string
	TCPOK      bool
	TCPMs      time.Duration
	Avg        time.Duration
	History    []bool          // loss %
	Latencies  []time.Duration // sparkline + avg
}

// ───────────────────────── styles ─────────────────────────

var (
	titleStyle   = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("42"))
	sectionStyle = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("39"))
	labelStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("244")).Width(9)
	keyStyle     = lipgloss.NewStyle().Foreground(lipgloss.Color("244"))
	valueStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("252"))
	dimStyle     = lipgloss.NewStyle().Foreground(lipgloss.Color("238"))
	errStyle     = lipgloss.NewStyle().Foreground(lipgloss.Color("203"))
	okDot        = lipgloss.NewStyle().Foreground(lipgloss.Color("42"))
	warnDot      = lipgloss.NewStyle().Foreground(lipgloss.Color("220"))
	badDot       = lipgloss.NewStyle().Foreground(lipgloss.Color("203"))
	sparkStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("45"))

	trafficWhiteStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("15"))

	boxStyle = lipgloss.NewStyle().
			Padding(0, 1)
)

const (
	targetW = 14
	dnsW    = 6
	ipW     = 16
	tcpW    = 7
	avgW    = 7
	lossW   = 5

	cTargetW = 12
	cDNSW    = 7
	cTCPW    = 7
	cLossW   = 5
)

// ───────────────────────── messages ─────────────────────────

type (
	probeTickMsg   struct{}
	trafficTickMsg struct{}
	slowTickMsg    struct{}
	wifiTickMsg    struct{}
	geoTickMsg     struct{}
	pulseTickMsg   struct{}

	probeResult struct {
		DNSOK   bool
		DNSTime time.Duration
		IP      string
		TCPOK   bool
		TCPMs   time.Duration
	}
	probeMsg struct{ results []probeResult }
	wifiMsg  struct{ w WiFiInfo }
	lanMsg   struct{ l LANInfo }
	geoMsg   struct {
		g   Geo
		err error
	}
	trafficMsg struct {
		rx, tx uint64
		ok     bool
	}
	pulseMsg struct{}
)

// ───────────────────────── model ─────────────────────────

type model struct {
	wifi       WiFiInfo
	lan        LANInfo
	geo        Geo
	geoErr     string
	geoAt      time.Time
	downBps    float64
	upBps      float64
	lastRx     uint64
	lastTx     uint64
	lastTrafAt time.Time
	trafficSet bool

	services []*Service
	inet     *Service // 1.1.1.1:53 hidden internet probe
	start    time.Time
	width    int
	height   int
	pulse    int
	probing  bool
	slowing  bool
}

func initialModel() model {
	return model{
		start: time.Now(),
		services: []*Service{
			{Name: "bing.com", Host: "bing.com:443"},
			{Name: "google.com", Host: "google.com:443"},
			{Name: "reddit.com", Host: "reddit.com:443"},
			{Name: "github.com", Host: "github.com:443"},
			{Name: "huggingface.co", Host: "huggingface.co:443"},
			{Name: "baidu.com", Host: "baidu.com:443"},
			{Name: "cloudflare.com", Host: "cloudflare.com:443"},
		},
		inet: &Service{Name: "internet", Host: "1.1.1.1:53"},
	}
}

// ───────────────────────── ticks ─────────────────────────

func probeTick() tea.Cmd {
	return tea.Tick(2*time.Second, func(time.Time) tea.Msg { return probeTickMsg{} })
}
func trafficTick() tea.Cmd {
	return tea.Tick(time.Second, func(time.Time) tea.Msg { return trafficTickMsg{} })
}
func slowTick() tea.Cmd {
	return tea.Tick(5*time.Second, func(time.Time) tea.Msg { return slowTickMsg{} })
}
func wifiTick() tea.Cmd {
	return tea.Tick(15*time.Second, func(time.Time) tea.Msg { return wifiTickMsg{} })
}
func geoTick() tea.Cmd {
	return tea.Tick(5*time.Minute, func(time.Time) tea.Msg { return geoTickMsg{} })
}
func pulseTick() tea.Cmd {
	return tea.Tick(400*time.Millisecond, func(time.Time) tea.Msg { return pulseMsg{} })
}

// ───────────────────────── commands ─────────────────────────

func (m model) probeCmd() tea.Cmd {
	services := m.services
	inet := m.inet
	return func() tea.Msg {
		all := append([]*Service{}, services...)
		all = append(all, inet)
		results := make([]probeResult, len(all))
		var wg sync.WaitGroup
		for i, s := range all {
			wg.Add(1)
			go func(i int, s *Service) {
				defer wg.Done()
				host, _, _ := net.SplitHostPort(s.Host)

				ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
				defer cancel()
				start := time.Now()
				addrs, dnsErr := net.DefaultResolver.LookupHost(ctx, host)
				dnsDur := time.Since(start)
				var ip string
				if dnsErr == nil {
					for _, a := range addrs {
						if net.ParseIP(a).To4() != nil {
							ip = a
							break
						}
					}
					if ip == "" && len(addrs) > 0 {
						ip = addrs[0]
					}
				}

				start = time.Now()
				conn, tcpErr := net.DialTimeout("tcp", s.Host, 2*time.Second)
				tcpDur := time.Since(start)
				if conn != nil {
					conn.Close()
				}
				results[i] = probeResult{
					DNSOK:   dnsErr == nil && ip != "",
					DNSTime: dnsDur,
					IP:      ip,
					TCPOK:   tcpErr == nil,
					TCPMs:   tcpDur,
				}
			}(i, s)
		}
		wg.Wait()
		return probeMsg{results}
	}
}

func (m model) wifiCmd() tea.Cmd {
	return func() tea.Msg { return wifiMsg{getWiFi()} }
}

func (m model) lanCmd() tea.Cmd {
	return func() tea.Msg {
		l := LANInfo{
			IP:         getLocalIP(),
			Gateway:    getGateway(),
			DNSServers: getDNSServers(),
		}
		if l.Gateway != "" {
			d, ok := pingHost(l.Gateway)
			l.GatewayPing, l.GatewayOK = d, ok
		}
		return lanMsg{l}
	}
}

func (m model) geoCmd() tea.Cmd {
	return func() tea.Msg {
		g, err := fetchGeo()
		return geoMsg{g, err}
	}
}

func (m model) trafficCmd() tea.Cmd {
	return func() tea.Msg {
		rx, tx, ok := readTraffic()
		return trafficMsg{rx, tx, ok}
	}
}

// ───────────────────────── init / update ─────────────────────────

func (m model) Init() tea.Cmd {
	return tea.Batch(
		m.probeCmd(), m.wifiCmd(), m.lanCmd(), m.geoCmd(), m.trafficCmd(),
		probeTick(), wifiTick(), slowTick(), geoTick(),
		trafficTick(), pulseTick(),
	)
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "q", "Q", "ctrl+c", "esc":
			return m, tea.Quit
		}
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height

	case probeTickMsg:
		if m.probing {
			return m, probeTick()
		}
		m.probing = true
		return m, tea.Batch(m.probeCmd(), probeTick())

	case probeMsg:
		m.probing = false
		for i, r := range msg.results {
			var s *Service
			if i < len(m.services) {
				s = m.services[i]
			} else if i == len(m.services) {
				s = m.inet
			} else {
				continue
			}
			s.DNSOK, s.DNSTime, s.ResolvedIP = r.DNSOK, r.DNSTime, r.IP
			s.TCPOK, s.TCPMs = r.TCPOK, r.TCPMs
			s.History = append(s.History, r.TCPOK)
			if len(s.History) > 100 {
				s.History = s.History[len(s.History)-100:]
			}
			if r.TCPOK {
				s.Latencies = append(s.Latencies, r.TCPMs)
				if len(s.Latencies) > 100 {
					s.Latencies = s.Latencies[len(s.Latencies)-100:]
				}
				var sum time.Duration
				for _, d := range s.Latencies {
					sum += d
				}
				s.Avg = sum / time.Duration(len(s.Latencies))
			}
		}

	case slowTickMsg:
		if m.slowing {
			return m, slowTick()
		}
		m.slowing = true
		return m, tea.Batch(m.lanCmd(), slowTick())

	case wifiTickMsg:
		return m, tea.Batch(m.wifiCmd(), wifiTick())

	case geoTickMsg:
		return m, tea.Batch(m.geoCmd(), geoTick())

	case trafficTickMsg:
		return m, tea.Batch(m.trafficCmd(), trafficTick())

	case pulseMsg:
		m.pulse++
		return m, pulseTick()

	case wifiMsg:
		m.wifi = msg.w
	case lanMsg:
		m.lan = msg.l
		m.slowing = false
	case geoMsg:
		if msg.err != nil {
			m.geoErr = msg.err.Error()
		} else {
			m.geo, m.geoErr, m.geoAt = msg.g, "", time.Now()
		}
	case trafficMsg:
		if msg.ok {
			now := time.Now()
			if m.trafficSet {
				if dt := now.Sub(m.lastTrafAt).Seconds(); dt > 0.05 {
					m.downBps = float64(msg.rx-m.lastRx) / dt
					m.upBps = float64(msg.tx-m.lastTx) / dt
				}
			}
			m.lastRx, m.lastTx, m.lastTrafAt, m.trafficSet = msg.rx, msg.tx, now, true
		}
	}
	return m, nil
}

// ───────────────────────── view ─────────────────────────

func (m model) View() string {
	if m.width == 0 || m.height == 0 {
		return ""
	}
	if m.width < 30 || m.height < 12 {
		return lipgloss.NewStyle().Foreground(lipgloss.Color("203")).Render(
			fmt.Sprintf("Terminal too small — need at least 30x12 (have %dx%d)\n", m.width, m.height))
	}

	compact := m.width < 72

	innerW := m.width - 6
	if innerW > 100 {
		innerW = 100
	}
	if innerW < 38 {
		innerW = 38
	}

	online := 0
	for _, s := range m.services {
		if s.TCPOK {
			online++
		}
	}

	pc := "42"
	if m.pulse%2 == 0 {
		pc = "48"
	}
	live := lipgloss.NewStyle().Foreground(lipgloss.Color(pc)).Render("●")

	cntStyle := okDot
	if online == 0 {
		cntStyle = badDot
	} else if online < len(m.services) {
		cntStyle = warnDot
	}

	var head string
	if compact {
		head = fmt.Sprintf("%s %s  %s  %s",
			titleStyle.Render("NETMON"), live, time.Now().Format("15:04:05"),
			cntStyle.Render(fmt.Sprintf("%d/%d", online, len(m.services))))
	} else {
		head = lipgloss.JoinHorizontal(lipgloss.Center,
			titleStyle.Render("NET MONITOR"), "  ", live,
			fmt.Sprintf("  %s   uptime %s   online %s",
				time.Now().Format("15:04:05"), fmtDur(time.Since(m.start)),
				cntStyle.Render(fmt.Sprintf("%d/%d", online, len(m.services)))))
	}

	lines := []string{head}
	if !compact {
		lines = append(lines, "")
	}

	if compact {
		wifiStr := "N/A"
		if m.wifi.SSID != "" {
			wifiStr = valueStyle.Render(m.wifi.SSID)
			if m.wifi.SignalPct > 0 {
				wifiStr += " " + signalStyle(m.wifi.SignalPct).Render(fmt.Sprintf("sig %d%%", m.wifi.SignalPct))
			}
			if m.wifi.Band != "" {
				wifiStr += " " + grayStyle(m.wifi.Band)
			}
		}

		lanStr := m.lan.IP
		if m.lan.Gateway != "" {
			gw := m.lan.Gateway
			if m.lan.GatewayOK {
				gw += fmt.Sprintf(" %dms", m.lan.GatewayPing.Milliseconds())
			} else {
				gw += " X"
			}
			lanStr += " gw " + gw
		}

		pubStr := m.geo.IP
		if m.geoErr != "" {
			pubStr = "pending..."
		} else if flag := countryFlag(m.geo.Country); flag != "" {
			pubStr += " " + flag
		}

		lines = append(lines,
			kvCColored("WiFi", wifiStr),
			kvC("LAN", lanStr),
			kvCColored("Pub", pubStr),
			kvCColored("Trf", trafficDisplay(m.downBps, m.upBps)),
			sectionStyle.Render("SERVICES"),
		)
	} else {
		if m.wifi.SSID != "" {
			var b strings.Builder
			b.WriteString(valueStyle.Render(m.wifi.SSID))
			if m.wifi.SignalPct > 0 {
				b.WriteString(" ")
				b.WriteString(signalStyle(m.wifi.SignalPct).Render(fmt.Sprintf("sig %d%%", m.wifi.SignalPct)))
			}
			var rest []string
			if m.wifi.Band != "" {
				rest = append(rest, m.wifi.Band)
			}
			if m.wifi.Channel > 0 {
				rest = append(rest, fmt.Sprintf("ch%d", m.wifi.Channel))
			}
			if m.wifi.Standard != "" {
				rest = append(rest, m.wifi.Standard)
			}
			if m.wifi.RxMbps > 0 || m.wifi.TxMbps > 0 {
				rest = append(rest, fmt.Sprintf("%.1f/%.1f Mbps", m.wifi.RxMbps, m.wifi.TxMbps))
			}
			if len(rest) > 0 {
				b.WriteString("  ")
				b.WriteString(grayStyle(strings.Join(rest, "  ")))
			}
			lines = append(lines, kvStyled("WiFi", b.String()))
		} else {
			lines = append(lines, kv("WiFi", dimStyle.Render("no wireless interface")))
		}

		lanParts := []string{orNA(m.lan.IP)}
		if m.lan.Gateway != "" {
			gw := m.lan.Gateway
			if m.lan.GatewayOK {
				gw += fmt.Sprintf(" %s", pingColor(m.lan.GatewayPing, m.lan.GatewayPing.Milliseconds()))
			} else {
				gw += " " + badDot.Render("timeout")
			}
			lanParts = append(lanParts, "gw "+gw)
		}
		if len(m.lan.DNSServers) > 0 {
			lanParts = append(lanParts, "DNS "+strings.Join(m.lan.DNSServers, ", "))
		}
		lines = append(lines, kv("LAN", strings.Join(lanParts, "  ")))

		if m.geoErr != "" {
			lines = append(lines,
				kv("Public", dimStyle.Render("pending…")),
				kv("", errStyle.Render(m.geoErr)),
			)
		} else {
			ipDisplay := orNA(m.geo.IP)
			if flag := countryFlag(m.geo.Country); flag != "" {
				ipDisplay += " " + flag
			}
			lines = append(lines,
				kv("Public", fmt.Sprintf("%s  %s, %s", ipDisplay, orNA(m.geo.City), orNA(m.geo.Country))),
			)
			ago := ""
			if !m.geoAt.IsZero() {
				ago = fmt.Sprintf("  %s", dimStyle.Render(fmt.Sprintf("(%.0fs ago)", time.Since(m.geoAt).Seconds())))
			}
			lines = append(lines, kv("", orNA(m.geo.Org)+ago))
		}

		lines = append(lines, kvStyled("Traffic", trafficDisplay(m.downBps, m.upBps)))
		lines = append(lines, "", sectionStyle.Render("SERVICES"), "")
	}

	if compact {
		lines = append(lines, compactTableHeader())
		for _, s := range m.services {
			lines = append(lines, serviceRowCompact(s))
		}
		lines = append(lines, "")
	} else {
		lines = append(lines, tableHeader())
		for _, s := range m.services {
			lines = append(lines, serviceRow(s))
		}
		lines = append(lines, "")
	}

	gwLoss, _ := lossPct(m.inetGatewayHistory(), 30)
	inetLoss, _ := lossPct(m.inet.History, 30)

	if compact {
		summary := fmt.Sprintf("loss: gw %s  inet %s  avg %s", coloredPct(gwLoss), coloredPct(inetLoss), durStr(m.inet.Avg))
		lines = append(lines, "  "+dimStyle.Render(summary), dimStyle.Render("  q to quit"))
	} else {
		summary := fmt.Sprintf("loss(last 30):  gateway %s  internet(1.1.1.1) %s  inet avg %s", coloredPct(gwLoss), coloredPct(inetLoss), durStr(m.inet.Avg))
		lines = append(lines, "  "+dimStyle.Render(summary), "", dimStyle.Render("  press q to quit"))
	}

	pad := 1
	if compact {
		pad = 0
	}

	box := boxStyle.Width(innerW).Padding(0, pad).Render(lipgloss.JoinVertical(lipgloss.Left, lines...))
	return lipgloss.Place(m.width, m.height, lipgloss.Center, lipgloss.Top, box)
}

func tableHeader() string {
	return "  " +
		keyStyle.Width(targetW).Render("TARGET") + " " +
		keyStyle.Width(dnsW).Align(lipgloss.Right).Render("DNS") + " " +
		keyStyle.Width(ipW).Render("RESOLVED IP") + " " +
		keyStyle.Width(tcpW).Align(lipgloss.Right).Render("TCP") + " " +
		keyStyle.Width(avgW).Align(lipgloss.Right).Render("avg") + " " +
		keyStyle.Width(lossW).Align(lipgloss.Right).Render("loss")
}

func compactTableHeader() string {
	return "  " +
		keyStyle.Width(cTargetW).Render("TARGET") + " " +
		keyStyle.Width(cDNSW).Align(lipgloss.Right).Render("DNS") + " " +
		keyStyle.Width(cTCPW).Align(lipgloss.Right).Render("TCP") + " " +
		keyStyle.Width(cLossW).Align(lipgloss.Right).Render("loss")
}

func serviceRow(s *Service) string {
	row := serviceRowStyle(s)

	dns := "--"
	if s.DNSOK {
		dns = fmt.Sprintf("%dms", s.DNSTime.Milliseconds())
	}

	ip := "--"
	if s.ResolvedIP != "" {
		ip = s.ResolvedIP
	}

	tcp := "timeout"
	if s.TCPOK {
		tcp = fmt.Sprintf("%dms", s.TCPMs.Milliseconds())
	}

	avg := "--"
	if s.Avg > 0 {
		avg = durStr(s.Avg)
	}

	loss := lossPctText(s.History)

	return "  " +
		row.Width(targetW).Render(truncate(s.Name, targetW)) + " " +
		row.Width(dnsW).Align(lipgloss.Right).Render(dns) + " " +
		row.Width(ipW).Render(ip) + " " +
		row.Width(tcpW).Align(lipgloss.Right).Render(tcp) + " " +
		row.Width(avgW).Align(lipgloss.Right).Render(avg) + " " +
		row.Width(lossW).Align(lipgloss.Right).Render(loss)
}

func serviceRowCompact(s *Service) string {
	row := serviceRowStyle(s)

	dns := "--"
	if s.DNSOK {
		dns = fmt.Sprintf("%dms", s.DNSTime.Milliseconds())
	}

	tcp := "timeout"
	if s.TCPOK {
		tcp = fmt.Sprintf("%dms", s.TCPMs.Milliseconds())
	}

	loss := lossPctText(s.History)

	return "  " +
		row.Width(cTargetW).Render(truncate(s.Name, cTargetW)) + " " +
		row.Width(cDNSW).Align(lipgloss.Right).Render(dns) + " " +
		row.Width(cTCPW).Align(lipgloss.Right).Render(tcp) + " " +
		row.Width(cLossW).Align(lipgloss.Right).Render(loss)
}

// serviceRowStyle decides the color for the ENTIRE row:
// connectivity + packet loss + latency.
func serviceRowStyle(s *Service) lipgloss.Style {
	if !s.TCPOK {
		return badDot
	}
	p, n := lossPct(s.History, len(s.History))
	if n > 0 && p > 10 {
		return badDot
	}
	if n > 0 && p > 1 {
		return warnDot
	}
	// use avg latency for stable coloring, fall back to current probe
	ms := s.Avg.Milliseconds()
	if ms == 0 {
		ms = s.TCPMs.Milliseconds()
	}
	if ms > 300 {
		return badDot
	}
	if ms > 100 {
		return warnDot
	}
	return okDot
}

// ───────────────────────── formatting helpers ─────────────────────────

func kvC(label, value string) string {
	return lipgloss.NewStyle().Foreground(lipgloss.Color("244")).Width(5).Render(label) + valueStyle.Render(value)
}

func kvCColored(label, value string) string {
	return lipgloss.NewStyle().Foreground(lipgloss.Color("244")).Width(5).Render(label) + value
}

func kv(label, value string) string {
	return labelStyle.Render(label) + valueStyle.Render(value)
}

func kvStyled(label, value string) string {
	return labelStyle.Render(label) + value
}

func grayStyle(s string) string {
	return lipgloss.NewStyle().Foreground(lipgloss.Color("244")).Render(s)
}

func signalStyle(pct int) lipgloss.Style {
	switch {
	case pct >= 75:
		return okDot
	case pct >= 50:
		return warnDot
	default:
		return dimStyle
	}
}

// trafficDisplay colors each direction independently:
// <200 KB/s stays white, >=200 KB/s turns green.
func trafficDisplay(down, up float64) string {
	const threshold = 200 * 1024 // bytes/sec

	dStyle := trafficWhiteStyle
	if down >= threshold {
		dStyle = okDot
	}
	uStyle := trafficWhiteStyle
	if up >= threshold {
		uStyle = okDot
	}
	return dStyle.Render("↓ " + fmtBps(down)) + "   " + uStyle.Render("↑ " + fmtBps(up))
}

func pingColor(d time.Duration, ms int64) string {
	c := okDot
	if ms > 300 {
		c = warnDot
	}
	if ms > 800 {
		c = badDot
	}
	return c.Render(fmt.Sprintf("%dms", ms))
}

func durStr(d time.Duration) string {
	if d == 0 {
		return "--"
	}
	return fmt.Sprintf("%dms", d.Milliseconds())
}

func fmtBps(b float64) string {
	units := []string{"B", "KB", "MB", "GB"}
	i := 0
	for b >= 1024 && i < len(units)-1 {
		b /= 1024
		i++
	}
	if i == 0 {
		return fmt.Sprintf("%.0f %s/s", b, units[i])
	}
	return fmt.Sprintf("%.1f %s/s", b, units[i])
}

func lossPct(history []bool, window int) (float64, int) {
	if len(history) == 0 {
		return 0, 0
	}
	if len(history) > window {
		history = history[len(history)-window:]
	}
	loss := 0
	for _, ok := range history {
		if !ok {
			loss++
		}
	}
	return float64(loss) / float64(len(history)) * 100, len(history)
}

func lossPctText(history []bool) string {
	p, n := lossPct(history, len(history))
	if n == 0 {
		return "--"
	}
	return fmt.Sprintf("%.0f%%", p)
}

func coloredPct(p float64) string {
	c := okDot
	if p > 1 {
		c = warnDot
	}
	if p > 10 {
		c = badDot
	}
	return c.Render(fmt.Sprintf("%.0f%%", p))
}

func (m model) inetGatewayHistory() []bool {
	return m.inet.History
}

func orNA(s string) string {
	if s == "" {
		return "N/A"
	}
	return s
}

func fmtDur(d time.Duration) string {
	d = d.Round(time.Second)
	h, mi, s := int(d.Hours()), int(d.Minutes())%60, int(d.Seconds())%60
	return fmt.Sprintf("%02d:%02d:%02d", h, mi, s)
}

func truncate(s string, w int) string {
	if w <= 0 {
		return ""
	}
	r := []rune(s)
	if len(r) <= w {
		return s
	}
	if w == 1 {
		return string(r[:1])
	}
	return string(r[:w-1]) + "…"
}

// countryFlag returns a bracketed emoji flag so the bounds are always clear
// even on terminals that fall back to rendering regional indicators as text.
func countryFlag(code string) string {
	code = strings.ToUpper(strings.TrimSpace(code))
	if len(code) != 2 {
		return ""
	}
	r := []rune(code)
	if r[0] < 'A' || r[0] > 'Z' || r[1] < 'A' || r[1] > 'Z' {
		return ""
	}
	return "[" + string([]rune{
		rune(0x1F1E6 + (r[0] - 'A')),
		rune(0x1F1E6 + (r[1] - 'A')),
	}) + "]"
}

// ───────────────────────── probes ─────────────────────────

func readTraffic() (uint64, uint64, bool) {
	counters, err := gnet.IOCounters(true)
	if err != nil {
		return 0, 0, false
	}
	var rx, tx uint64
	for _, c := range counters {
		if c.Name == "lo" || strings.Contains(strings.ToLower(c.Name), "loopback") {
			continue
		}
		rx += c.BytesRecv
		tx += c.BytesSent
	}
	return rx, tx, true
}

var (
	pingUnix = regexp.MustCompile(`time[=<]([\d.]+)\s*ms`)
)

func pingHost(host string) (time.Duration, bool) {
	if host == "" {
		return 0, false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "windows":
		cmd = exec.CommandContext(ctx, "powershell", "-NoProfile", "-Command",
			fmt.Sprintf("Test-Connection -Count 1 -Target %s -ErrorAction Stop | Select-Object -ExpandProperty ResponseTime", host))
	case "darwin":
		cmd = exec.CommandContext(ctx, "ping", "-c", "1", "-W", "1000", host)
	default:
		cmd = exec.CommandContext(ctx, "ping", "-c", "1", "-W", "1", host)
	}
	out, err := cmd.Output()
	if err != nil {
		return 0, false
	}

	if runtime.GOOS == "windows" {
		s := strings.TrimSpace(string(out))
		ms, err := strconv.ParseFloat(s, 64)
		if err != nil {
			return 0, false
		}
		return time.Duration(ms) * time.Millisecond, true
	}
	m := pingUnix.FindStringSubmatch(string(out))
	if len(m) < 2 {
		return 0, false
	}
	ms, err := strconv.ParseFloat(m[1], 64)
	if err != nil {
		return 0, false
	}
	return time.Duration(ms * float64(time.Millisecond)), true
}

func fetchGeo() (Geo, error) {
	client := &http.Client{Timeout: 6 * time.Second}
	resp, err := client.Get("https://ipinfo.io/json")
	if err != nil {
		return Geo{}, err
	}
	defer resp.Body.Close()
	var g Geo
	if err := json.NewDecoder(resp.Body).Decode(&g); err != nil {
		return Geo{}, err
	}
	return g, nil
}

func getLocalIP() string {
	conn, err := net.Dial("udp", "8.8.8.8:80")
	if err != nil {
		return ""
	}
	defer conn.Close()
	return conn.LocalAddr().(*net.UDPAddr).IP.String()
}

// ───────────────────────── gateway / DNS (per-OS) ─────────────────────────

func getGateway() string {
	switch runtime.GOOS {
	case "darwin":
		out, err := exec.Command("route", "-n", "get", "default").Output()
		if err != nil {
			return ""
		}
		for _, ln := range strings.Split(string(out), "\n") {
			ln = strings.TrimSpace(ln)
			if strings.HasPrefix(ln, "gateway:") {
				return strings.TrimSpace(strings.TrimPrefix(ln, "gateway:"))
			}
		}
	case "linux":
		out, err := exec.Command("ip", "route", "show", "default").Output()
		if err != nil {
			return ""
		}
		f := strings.Fields(string(out))
		for i, w := range f {
			if w == "via" && i+1 < len(f) {
				return f[i+1]
			}
		}
	case "windows":
		out, err := exec.Command("powershell", "-NoProfile", "-Command",
			"(Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1).NextHop").Output()
		if err == nil {
			return strings.TrimSpace(string(out))
		}
	}
	return ""
}

func getDNSServers() []string {
	switch runtime.GOOS {
	case "darwin":
		out, err := exec.Command("scutil", "--dns").Output()
		if err != nil {
			return nil
		}
		var servers []string
		seen := map[string]bool{}
		for _, ln := range strings.Split(string(out), "\n") {
			ln = strings.TrimSpace(ln)
			if strings.HasPrefix(ln, "nameserver[") {
				f := strings.Fields(ln)
				if len(f) >= 3 && !seen[f[2]] {
					seen[f[2]] = true
					servers = append(servers, f[2])
				}
			}
		}
		return servers
	case "linux":
		data, err := os.ReadFile("/etc/resolv.conf")
		if err != nil {
			return nil
		}
		var servers []string
		for _, ln := range strings.Split(string(data), "\n") {
			ln = strings.TrimSpace(ln)
			if strings.HasPrefix(ln, "nameserver ") {
				servers = append(servers, strings.TrimSpace(strings.TrimPrefix(ln, "nameserver ")))
			}
		}
		return servers
	case "windows":
		out, err := exec.Command("powershell", "-NoProfile", "-Command",
			"(Get-DnsClientServerAddress -AddressFamily IPv4).ServerAddresses -join ','").Output()
		if err != nil {
			return nil
		}
		s := strings.TrimSpace(string(out))
		if s == "" {
			return nil
		}
		return strings.Split(s, ",")
	}
	return nil
}

// ───────────────────────── WiFi (per-OS) ─────────────────────────

func getWiFi() WiFiInfo {
	switch runtime.GOOS {
	case "linux":
		return linuxWiFi()
	case "darwin":
		return macWiFi()
	case "windows":
		return windowsWiFi()
	}
	return WiFiInfo{}
}

func linuxWiFi() WiFiInfo {
	if out, err := exec.Command("nmcli", "-t", "-f", "ACTIVE,SIGNAL,RATE,CHAN,FREQ,SSID", "dev", "wifi").Output(); err == nil {
		for _, ln := range strings.Split(string(out), "\n") {
			if !strings.HasPrefix(ln, "yes:") {
				continue
			}
			f := strings.Split(ln, ":")
			if len(f) < 6 {
				continue
			}
			w := WiFiInfo{SSID: f[5]}
			w.SignalPct, _ = strconv.Atoi(f[1])
			rx := strings.TrimSuffix(strings.TrimSpace(f[2]), " Mbit/s")
			if v, err := strconv.ParseFloat(rx, 64); err == nil {
				w.RxMbps, w.TxMbps = v, v
			}
			w.Channel, _ = strconv.Atoi(f[3])
			if f[4] != "" {
				var freq int
				fmt.Sscanf(f[4], "%d MHz", &freq)
				if freq >= 5000 {
					w.Band = "5 GHz"
				} else {
					w.Band = "2.4 GHz"
				}
				w.Standard = inferStandard(freq, w.RxMbps)
			}
			return w
		}
	}

	if out, err := exec.Command("iwgetid", "-r").Output(); err == nil {
		ssid := strings.TrimSpace(string(out))
		if ssid != "" {
			return WiFiInfo{SSID: ssid}
		}
	}
	return WiFiInfo{}
}

func inferStandard(freqMHz int, mbps float64) string {
	if freqMHz >= 5000 {
		if mbps >= 400 {
			return "802.11ac"
		}
		return "802.11a"
	}
	if mbps >= 200 {
		return "802.11n"
	}
	return "802.11g"
}

func macWiFi() WiFiInfo {
	out, err := exec.Command("system_profiler", "SPAirPortDataType", "-json").Output()
	if err != nil {
		return WiFiInfo{}
	}
	var root map[string]any
	if err := json.Unmarshal(out, &root); err != nil {
		return WiFiInfo{}
	}
	w := WiFiInfo{}
	walk(root, func(k string, v any) {
		ks := strings.ToLower(k)
		switch {
		case ks == "_name" && w.SSID == "":
			if s, ok := v.(string); ok {
				w.SSID = s
			}
		case strings.Contains(ks, "channel"):
			if s, ok := v.(string); ok {
				fmt.Sscanf(s, "%d", &w.Channel)
				if strings.Contains(s, "5GHz") {
					w.Band = "5 GHz"
				} else if strings.Contains(s, "2.4GHz") {
					w.Band = "2.4 GHz"
				}
			}
		case strings.Contains(ks, "phymode"):
			if s, ok := v.(string); ok {
				w.Standard = s
			}
		case strings.Contains(ks, "signal") || strings.Contains(ks, "noise"):
			if s, ok := v.(string); ok {
				var dbm int
				fmt.Sscanf(s, "%d", &dbm)
				if dbm < 0 && dbm > -100 {
					w.SignalPct = clamp(2*(dbm+100), 0, 100)
				}
			}
		case strings.Contains(ks, "rate") && w.RxMbps == 0:
			switch x := v.(type) {
			case float64:
				w.RxMbps, w.TxMbps = x, x
			}
		}
	})
	return w
}

func windowsWiFi() WiFiInfo {
	out, err := exec.Command("netsh", "wlan", "show", "interfaces").Output()
	if err != nil {
		return WiFiInfo{}
	}
	w := WiFiInfo{}
	for _, ln := range strings.Split(string(out), "\n") {
		ln = strings.TrimSpace(ln)
		idx := strings.Index(ln, ":")
		if idx < 0 {
			continue
		}
		key := strings.TrimSpace(ln[:idx])
		val := strings.TrimSpace(ln[idx+1:])
		switch key {
		case "SSID":
			if w.SSID == "" {
				w.SSID = val
			}
		case "Signal":
			w.SignalPct, _ = strconv.Atoi(strings.TrimSuffix(val, "%"))
		case "Channel":
			w.Channel, _ = strconv.Atoi(val)
		case "Radio type":
			w.Standard = val
		case "Receive rate (Mbps)":
			w.RxMbps, _ = strconv.ParseFloat(val, 64)
		case "Transmit rate (Mbps)":
			w.TxMbps, _ = strconv.ParseFloat(val, 64)
		}
	}
	if w.Channel > 0 {
		if w.Channel >= 32 {
			w.Band = "5 GHz"
		} else {
			w.Band = "2.4 GHz"
		}
	}
	return w
}

func clamp(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

func walk(v any, fn func(key string, val any)) {
	switch x := v.(type) {
	case map[string]any:
		for k, val := range x {
			fn(k, val)
			walk(val, fn)
		}
	case []any:
		for _, e := range x {
			walk(e, fn)
		}
	}
}

// ───────────────────────── main ─────────────────────────

func main() {
	p := tea.NewProgram(initialModel(), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Println("error:", err)
		os.Exit(1)
	}
}