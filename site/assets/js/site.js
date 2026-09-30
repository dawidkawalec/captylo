/* captylo.com: language switch, the hero demo, AI modes, tabs, the typing race. */
(function () {
  "use strict";

  var root = document.documentElement;
  var calm = window.matchMedia("(prefers-reduced-motion: reduce)");
  var lang = "pl";
  var onLang = [];

  /* ------------------------------------------------------------ language (data-en / data-pl) */
  function setLang(next) {
    lang = next === "en" ? "en" : "pl";
    var en = lang === "en";
    document.querySelectorAll("[data-en]").forEach(function (n) {
      if (n.dataset.pl === undefined) n.dataset.pl = n.textContent;
      n.textContent = en ? n.dataset.en : n.dataset.pl;
    });
    document.querySelectorAll("[data-en-alt]").forEach(function (n) {
      if (n.dataset.plAlt === undefined) n.dataset.plAlt = n.alt;
      n.alt = en ? n.dataset.enAlt : n.dataset.plAlt;
    });
    document.querySelectorAll("[data-en-aria]").forEach(function (n) {
      if (n.dataset.plAria === undefined) n.dataset.plAria = n.getAttribute("aria-label");
      n.setAttribute("aria-label", en ? n.dataset.enAria : n.dataset.plAria);
    });
    root.lang = lang;
    document.querySelectorAll(".lang button").forEach(function (b) {
      b.setAttribute("aria-pressed", String(b.dataset.lang === lang));
    });
    try { localStorage.setItem("captylo-lang", lang); } catch (e) {}
    onLang.forEach(function (f) { f(); });
  }
  document.querySelectorAll(".lang button").forEach(function (b) {
    b.addEventListener("click", function () { setLang(b.dataset.lang); });
  });
  var t = function (pl, en) { return lang === "en" ? en : pl; };

  /* ------------------------------------------------------------ header */
  var header = document.getElementById("header");
  function onScroll() { header.classList.toggle("is-scrolled", window.scrollY > 24); }
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  /* ------------------------------------------------------------ waveform (WaveformMath: bars under a gaussian bell) */
  var BARS = 15;
  function makeWave(el) {
    el.innerHTML = "";
    var bars = [];
    for (var i = 0; i < BARS; i++) { var b = document.createElement("i"); el.appendChild(b); bars.push(b); }
    return bars;
  }
  function bell(i) {
    var d = i - (BARS - 1) / 2;
    return Math.exp(-Math.pow(d / (BARS * 0.16), 2));
  }
  function paintWave(bars, level, time) {
    for (var i = 0; i < bars.length; i++) {
      var travel = 0.5 + 0.5 * Math.sin(time * 7.5 - i * 0.7) * Math.sin(time * 2.3 + i * 0.35);
      var floor = level > 0 ? 0.35 : 0;
      var amp = bell(i) * (floor + (1 - floor) * level * (0.45 + 0.55 * travel));
      bars[i].style.height = Math.max(3, Math.round(amp * 30)) + "px";
    }
  }
  /* a speech-like level: syllables on top of phrases, short pauses between words */
  function speech(time) {
    var phrase = 0.55 + 0.45 * Math.sin(time * 1.3) * Math.sin(time * 0.7 + 1);
    var syll = 0.5 + 0.5 * Math.abs(Math.sin(time * 9.1) * Math.sin(time * 3.7 + 0.4));
    var gap = Math.sin(time * 2.1) > 0.86 ? 0.25 : 1;
    return Math.min(1, Math.max(0.12, phrase * syll * gap * 1.25));
  }

  /* static waves (step 2): gently alive while on screen */
  var staticWaves = [];
  document.querySelectorAll('[data-wave="live"]').forEach(function (el) {
    var w = { bars: makeWave(el), visible: false, el: el };
    staticWaves.push(w);
    paintWave(w.bars, 0.85, 0.3);
  });

  /* ------------------------------------------------------------ hero demo */
  var SCENES = [
    {
      app: ["Wiadomości · #projekt", "Messages · #project"],
      who: "M", name: "Marta",
      said: ["Podeślesz ofertę przed jutrzejszym callem?", "Can you send the offer before tomorrow's call?"],
      text: ["Jasne, wrzuciłem poprawioną ofertę do folderu. Rzuć okiem na zakres prac, a jutro o 10 domkniemy temat z klientem.", "Sure, I've put the updated offer in the folder. Have a look at the scope, and tomorrow at 10 we'll close it with the client."],
      secs: 7
    },
    {
      app: ["Terminal · claude", "Terminal · claude"],
      who: ">", name: "Claude Code",
      said: ["Co robimy dalej?", "What's next?"],
      text: ["Przejrzyj ten komponent i zaproponuj, jak podzielić go na mniejsze części. Zachowaj obecne nazwy propsów i dodaj testy do każdej nowej funkcji.", "Review this component and suggest how to split it into smaller parts. Keep the current prop names and add tests for every new function."],
      secs: 9
    },
    {
      app: ["Poczta · Odpowiedź", "Mail · Reply"],
      who: "K", name: "Kasia",
      said: ["Czy możemy przesunąć spotkanie w tym tygodniu?", "Could we move this week's meeting?"],
      text: ["Dzień dobry, czwartek o 14 pasuje mi idealnie. Przyślę zaproszenie jeszcze dziś, a agendę dorzucę w mailu.", "Hi, Thursday at 2 pm works perfectly for me. I'll send the invite today and add the agenda in the email."],
      secs: 8
    }
  ];

  var demo = document.getElementById("demo");
  if (demo) (function () {
    var appEl = document.getElementById("demo-app");
    var thread = document.getElementById("demo-thread");
    var field = document.getElementById("demo-field");
    var textEl = document.getElementById("demo-text");
    var widget = document.getElementById("widget");
    var timer = document.getElementById("timer");
    var key = document.querySelector("#hotkey .keycap");
    var keyLabel = document.getElementById("hotkey-label");
    var bars = makeWave(document.getElementById("wave"));
    var scene = 0, timers = [], visible = true, running = false, phase = "idle", recStart = 0;

    function pick(v) { return Array.isArray(v) ? t(v[0], v[1]) : v; }
    function later(ms, f) { timers.push(setTimeout(f, ms)); }
    function clear() { timers.forEach(clearTimeout); timers = []; }
    function label(pl, en) { keyLabel.textContent = t(pl, en); }

    function setScene(i) {
      var s = SCENES[i];
      appEl.textContent = pick(s.app);
      thread.innerHTML = "";
      var m = document.createElement("div");
      m.className = "msg";
      m.innerHTML = '<span class="avatar" aria-hidden="true"></span><div><b></b><p></p></div>';
      m.querySelector(".avatar").textContent = s.who;
      m.querySelector("b").textContent = pick(s.name);
      m.querySelector("p").textContent = pick(s.said);
      thread.appendChild(m);
      textEl.textContent = "";
      field.classList.remove("is-pasted");
    }
    function finalState() {
      setScene(0);
      textEl.textContent = pick(SCENES[0].text);
      widget.classList.remove("is-on", "is-processing");
      key.classList.remove("is-down");
      label("Przytrzymaj prawy Option i mów", "Hold Right Option and speak");
    }

    function play() {
      clear();
      var s = SCENES[scene];
      phase = "idle";
      thread.style.opacity = 1; field.style.opacity = 1; appEl.style.opacity = 1;
      setScene(scene);
      widget.classList.remove("is-on", "is-processing");
      key.classList.remove("is-down");
      label("Przytrzymaj prawy Option", "Hold Right Option");
      var rec = 3600;
      later(900, function () {
        phase = "rec"; recStart = performance.now();
        key.classList.add("is-down");
        widget.classList.add("is-on");
        label("Mów swobodnie", "Speak freely");
      });
      later(900 + rec, function () {
        phase = "proc";
        key.classList.remove("is-down");
        widget.classList.add("is-processing");
        label("Puść. Tekst już jest.", "Let go. It's typed.");
      });
      later(900 + rec + 420, function () {
        phase = "done";
        widget.classList.remove("is-on");
        var span = document.createElement("span");
        span.className = "flash";
        span.textContent = pick(s.text);
        textEl.innerHTML = "";
        textEl.appendChild(span);
        field.classList.add("is-pasted");
        later(900, function () { span.classList.add("is-done"); field.classList.remove("is-pasted"); });
      });
      later(900 + rec + 420 + 3600, function () {
        thread.style.opacity = 0; field.style.opacity = 0; appEl.style.opacity = 0;
      });
      later(900 + rec + 420 + 3600 + 380, function () {
        widget.classList.remove("is-processing");
        scene = (scene + 1) % SCENES.length;
        if (running) play();
      });
    }

    function tick(now) {
      if (!running) return;
      var time = now / 1000;
      if (phase === "rec") {
        var el = (now - recStart) / 1000;
        var secs = Math.min(SCENES[scene].secs, Math.floor(el * SCENES[scene].secs / 3.4));
        timer.textContent = "00:" + (secs < 10 ? "0" : "") + secs;
        paintWave(bars, speech(time), time);
      } else if (phase === "proc") {
        paintWave(bars, 0.18, time * 0.5);
      } else if (phase === "idle") {
        timer.textContent = "00:00";
        paintWave(bars, 0.2, time);
      }
      requestAnimationFrame(tick);
    }

    function start() {
      if (running || calm.matches || !visible || document.hidden) return;
      running = true;
      play();
      requestAnimationFrame(tick);
    }
    function stop() { running = false; clear(); }

    [thread, field, appEl].forEach(function (e) { e.style.transition = "opacity .35s"; });
    if ("IntersectionObserver" in window) {
      new IntersectionObserver(function (es) {
        visible = es[0].isIntersecting;
        if (visible) start(); else stop();
      }, { threshold: 0.15 }).observe(demo);
    }
    document.addEventListener("visibilitychange", function () { if (document.hidden) stop(); else start(); });
    calm.addEventListener && calm.addEventListener("change", function () { if (calm.matches) { stop(); finalState(); } else start(); });
    onLang.push(function () {
      if (calm.matches) { finalState(); return; }
      if (running) { stop(); start(); } else setScene(scene);
    });
    paintWave(bars, 0.2, 0);
    if (calm.matches) finalState(); else start();
  })();

  /* static waves loop */
  if ("IntersectionObserver" in window) {
    var swIO = new IntersectionObserver(function (es) {
      es.forEach(function (e) { staticWaves.forEach(function (w) { if (w.el === e.target) w.visible = e.isIntersecting; }); });
    });
    staticWaves.forEach(function (w) { swIO.observe(w.el); });
    (function loop(now) {
      if (!calm.matches && !document.hidden) {
        var time = now / 1000;
        staticWaves.forEach(function (w) { if (w.visible) paintWave(w.bars, speech(time + 3), time + 3); });
      }
      requestAnimationFrame(loop);
    })(0);
  }

  /* ------------------------------------------------------------ AI modes */
  var AI = {
    rawPl: "<s>yyy no więc</s> chciałem zapytać czy <s>czy</s> dacie radę przesunąć spotkanie na <s>na</s> czwartek bo w środę mam <s>mam</s> wizytę",
    rawEn: "<s>umm so</s> I wanted to ask if <s>if</s> you could move the meeting to <s>to</s> thursday because on wednesday I have <s>I have</s> an appointment",
    modes: {
      clean: { ms: 0.9, pl: "Chciałem zapytać, czy dacie radę przesunąć spotkanie na czwartek, bo w środę mam wizytę.", en: "I wanted to ask if you could move the meeting to Thursday, because I have an appointment on Wednesday." },
      email: { ms: 1.4, pl: "Dzień dobry,\n\nczy dalibyście radę przesunąć nasze spotkanie na czwartek? W środę mam wizytę.\n\nPozdrawiam", en: "Hi,\n\ncould we move our meeting to Thursday? I have an appointment on Wednesday.\n\nBest regards" },
      todo: { ms: 1.1, pl: ["Poprosić o przesunięcie spotkania na czwartek", "Środa zajęta: wizyta"], en: ["Ask to move the meeting to Thursday", "Wednesday is taken: appointment"] },
      english: { ms: 1.2, pl: "I wanted to ask if you could move the meeting to Thursday, because I have an appointment on Wednesday.", en: "I wanted to ask if you could move the meeting to Thursday, because I have an appointment on Wednesday.", rawAlwaysPl: true },
      tidy: { ms: 1.0, pl: "Prośba: przesunięcie spotkania na czwartek.\nPowód: w środę mam wizytę.", en: "Request: move the meeting to Thursday.\nReason: an appointment on Wednesday." }
    }
  };
  var aiCard = document.getElementById("ai-card");
  if (aiCard) (function () {
    var raw = document.getElementById("ai-raw");
    var out = document.getElementById("ai-out");
    var nameEl = document.getElementById("ai-mode-name");
    var msEl = document.getElementById("ai-ms");
    var buttons = aiCard.querySelectorAll(".modes button");
    var current = "clean";
    function render() {
      var m = AI.modes[current];
      raw.innerHTML = m.rawAlwaysPl || lang === "pl" ? AI.rawPl : AI.rawEn;
      var v = lang === "en" ? m.en : m.pl;
      out.innerHTML = "";
      if (Array.isArray(v)) {
        var ul = document.createElement("ul");
        v.forEach(function (s) { var li = document.createElement("li"); li.textContent = s; ul.appendChild(li); });
        out.appendChild(ul);
      } else out.textContent = v;
      out.style.animation = "none"; void out.offsetWidth; out.style.animation = "";
      var btn = aiCard.querySelector('[data-mode="' + current + '"]');
      nameEl.textContent = t("Tryb ", "") + btn.textContent + (lang === "en" ? " mode" : "");
      msEl.textContent = (lang === "en" ? String(m.ms) : String(m.ms).replace(".", ",")) + " s";
    }
    function select(mode, focus) {
      current = mode;
      buttons.forEach(function (b) {
        var on = b.dataset.mode === mode;
        b.setAttribute("aria-checked", String(on));
        b.tabIndex = on ? 0 : -1;
        if (on && focus) b.focus();
      });
      render();
    }
    buttons.forEach(function (b, i) {
      b.addEventListener("click", function () { select(b.dataset.mode); });
      b.addEventListener("keydown", function (e) {
        var d = e.key === "ArrowRight" || e.key === "ArrowDown" ? 1 : e.key === "ArrowLeft" || e.key === "ArrowUp" ? -1 : 0;
        if (!d) return;
        e.preventDefault();
        select(buttons[(i + d + buttons.length) % buttons.length].dataset.mode, true);
      });
    });
    onLang.push(render);
    select("clean");
  })();

  /* ------------------------------------------------------------ the desktop: real apps, the widget records, the text lands */
  var DESK = {
    gmail: {
      app: ["Safari", "Safari"],
      menus: [["Plik", "Edycja", "Widok", "Historia", "Zakładki", "Okno", "Pomoc"], ["File", "Edit", "View", "History", "Bookmarks", "Window", "Help"]],
      name: "Gmail", what: ["w przeglądarce, odpowiedź do klienta", "in the browser, a reply to a client"],
      mode: ["E-mail", "Email"], ai: true, secs: 14,
      text: ["Dzień dobry Panie Tomaszu,\n\ndziękuję za przesłane materiały. Przejrzę je do czwartku i wrócę z uwagami do wyceny. Jeśli wygodniej będzie omówić je na krótkim callu, proszę dać znać, który termin pasuje.\n\nPozdrawiam,\nDawid",
             "Hello Tom,\n\nthank you for the materials. I'll go through them by Thursday and come back with my notes on the quote. If a short call is easier, let me know which slot suits you.\n\nBest regards,\nDawid"]
    },
    word: {
      app: ["Word", "Word"],
      menus: [["Plik", "Edycja", "Widok", "Wstaw", "Format", "Narzędzia", "Tabela", "Okno", "Pomoc"], ["File", "Edit", "View", "Insert", "Format", "Tools", "Table", "Window", "Help"]],
      name: "Word", what: ["raport kwartalny", "a quarterly report"],
      mode: ["Czyszczenie", "Cleanup"], ai: true, quiet: true, secs: 19,
      text: ["W trzecim kwartale liczba aktywnych klientów wzrosła o 18 procent. Największy wzrost widać w segmencie małych firm, gdzie skrócenie wdrożenia do dwóch tygodni podniosło konwersję z okresu próbnego.",
             "In the third quarter the number of active customers grew by 18 percent. The biggest growth came from small businesses, where cutting onboarding down to two weeks lifted the trial-to-paid conversion."]
    },
    code: {
      app: ["Code", "Code"],
      menus: [["Plik", "Edycja", "Zaznaczenie", "Widok", "Przejdź", "Uruchom", "Terminal", "Okno", "Pomoc"], ["File", "Edit", "Selection", "View", "Go", "Run", "Terminal", "Window", "Help"]],
      name: "Visual Studio Code", what: ["README projektu", "the project README"],
      mode: ["Czyszczenie", "Cleanup"], ai: true, quiet: true, secs: 9, lines: true,
      text: ["## Instalacja\n\nPobierz aplikację, przeciągnij ją do folderu Programy i przy pierwszym uruchomieniu zezwól na dostęp do mikrofonu i dostępności.",
             "## Installation\n\nDownload the app, drag it to Applications and on the first launch allow the microphone and Accessibility access."]
    },
    claude: {
      app: ["Terminal", "Terminal"],
      menus: [["Powłoka", "Edycja", "Widok", "Okno", "Pomoc"], ["Shell", "Edit", "View", "Window", "Help"]],
      name: "Claude Code", what: ["w terminalu, prompt dla agenta", "in the terminal, a prompt for the agent"],
      mode: ["Bez AI, prosto do terminala", "No AI, straight in"], ai: false, secs: 12,
      text: ["Przejrzyj testy w katalogu CaptyloTests i znajdź te, które sprawdzają wklejanie tekstu. Dopisz przypadek dla pustej transkrypcji i uruchom make test, zanim cokolwiek zmienisz w kodzie.",
             "Go through the tests in CaptyloTests and find the ones that cover pasting text. Add a case for an empty transcript and run make test before you change any code."]
    },
    tb: {
      app: ["Thunderbird", "Thunderbird"],
      menus: [["Plik", "Edycja", "Widok", "Wstaw", "Format", "Opcje", "Narzędzia", "Okno", "Pomoc"], ["File", "Edit", "View", "Insert", "Format", "Options", "Tools", "Window", "Help"]],
      name: "Thunderbird", what: ["mail do zespołu", "an email to the team"],
      mode: ["Czyszczenie", "Cleanup"], ai: true, quiet: true, secs: 11,
      text: ["Cześć,\n\nw piątek wdrażamy nową wersję. Proszę do czwartku do 16 zgłosić wszystkie otwarte błędy, a w piątek rano zróbcie jeszcze szybki test logowania i płatności.\n\nDzięki!",
             "Hi all,\n\nwe ship the new version on Friday. Please report every open bug by Thursday 4 pm, and on Friday morning run one more quick check of sign-in and payments.\n\nThanks!"]
    },
    slack: {
      app: ["Slack", "Slack"],
      menus: [["Plik", "Edycja", "Widok", "Przejdź", "Okno", "Pomoc"], ["File", "Edit", "View", "Go", "Window", "Help"]],
      name: "Slack", what: ["odpowiedź dla klientki z zagranicy, mówiona po polsku", "a reply to a client abroad, spoken in Polish"],
      mode: ["Po angielsku", "In English"], ai: true, secs: 10,
      text: ["Hi Anna, thanks for the update. The new timeline works for us. Let's lock Thursday for the review, and I'll send the agenda tomorrow morning.",
             "Hi Anna, thanks for the update. The new timeline works for us. Let's lock Thursday for the review, and I'll send the agenda tomorrow morning."]
    }
  };
  var desk = document.getElementById("desk");
  if (desk) (function () {
    var tabs = Array.prototype.slice.call(document.querySelectorAll(".dock-tabs [role=tab]"));
    var mbApp = document.getElementById("mb-app"), mbMenus = document.getElementById("mb-menus"), mbRec = document.getElementById("mb-captylo");
    var widget = document.getElementById("desk-widget"), timer = document.getElementById("desk-timer"), status = document.getElementById("desk-status");
    var caption = document.getElementById("desk-caption");
    var bars = makeWave(document.getElementById("desk-wave"));
    var order = tabs.map(function (b) { return b.getAttribute("aria-controls").replace("app-", ""); });
    var current = order[0], timers = [], phase = "idle", recStart = 0, visible = false, auto = true, running = false, loopOn = false;

    function pick(v) { return Array.isArray(v) ? (lang === "en" ? v[1] : v[0]) : v; }
    function later(ms, f) { timers.push(setTimeout(f, ms)); }
    function clear() { timers.forEach(clearTimeout); timers = []; }
    function target(id) { return document.querySelector('.paste-target[data-app="' + id + '"]'); }

    function resetTarget(id) {
      var el = target(id);
      el.querySelectorAll(".added,.flash,.app-caret").forEach(function (n) { n.remove(); });
      el.querySelectorAll(".cur").forEach(function (n) { n.classList.remove("cur"); });
      if (!DESK[id].lines) el.textContent = "";
      var host = DESK[id].lines ? el.lastElementChild : el;
      if (DESK[id].lines) { host.classList.remove("h2"); host.classList.add("cur"); }
      var c = document.createElement("span");
      c.className = "app-caret";
      host.appendChild(c);
    }
    function paste(id) {
      var d = DESK[id], el = target(id), text = pick(d.text), caret = el.querySelector(".app-caret");
      if (d.lines) {
        el.querySelectorAll(".cur").forEach(function (n) { n.classList.remove("cur"); });
        var last = null;
        text.split("\n").forEach(function (line, i) {
          var p = i === 0 ? el.lastElementChild : document.createElement("p");
          if (i > 0) { p.className = "added"; el.appendChild(p); }
          if (/^#+ /.test(line)) p.classList.add("h2");
          var s = document.createElement("span");
          s.className = "flash";
          s.textContent = line;
          p.insertBefore(s, i === 0 ? caret : null);
          last = p;
        });
        last.classList.add("cur");
        last.appendChild(caret);
      } else {
        var s = document.createElement("span");
        s.className = "flash";
        s.textContent = text;
        el.insertBefore(s, caret);
      }
      later(1000, function () { el.querySelectorAll(".flash").forEach(function (n) { n.classList.add("is-done"); }); });
    }
    function chrome(id) {
      var d = DESK[id];
      mbApp.textContent = pick(d.app);
      mbMenus.innerHTML = "";
      pick(d.menus).forEach(function (m) { var s = document.createElement("span"); s.textContent = m; mbMenus.appendChild(s); });
      caption.innerHTML = "";
      var b = document.createElement("b"); b.textContent = d.name;
      var mode = document.createElement("span"); mode.className = "mode";
      mode.textContent = d.ai ? (lang === "en" ? pick(d.mode) + " mode" : "Tryb " + pick(d.mode)) : pick(d.mode);
      caption.appendChild(b);
      caption.appendChild(document.createTextNode(" " + pick(d.what)));
      caption.appendChild(mode);
      caption.appendChild(document.createTextNode(t("powiedziane w 0:", "spoken in 0:") + (d.secs < 10 ? "0" : "") + d.secs));
    }
    function show(id) {
      current = id;
      tabs.forEach(function (b) {
        var on = b.getAttribute("aria-controls") === "app-" + id;
        b.setAttribute("aria-selected", String(on));
        b.tabIndex = on ? 0 : -1;
        document.getElementById(b.getAttribute("aria-controls")).hidden = !on;
      });
      chrome(id);
    }
    function finalState(id) {
      clear();
      show(id);
      resetTarget(id);
      paste(id);
      target(id).querySelectorAll(".flash").forEach(function (n) { n.classList.add("is-done"); });
      widget.classList.remove("is-on", "is-processing");
      mbRec.classList.remove("is-rec");
      phase = "idle";
    }
    function play(id) {
      clear();
      show(id);
      resetTarget(id);
      var d = DESK[id];
      phase = "idle";
      widget.classList.remove("is-on", "is-processing");
      mbRec.classList.remove("is-rec");
      status.textContent = "";
      var rec = 3200, t0 = 700;
      later(t0, function () {
        phase = "rec"; recStart = performance.now();
        widget.classList.add("is-on");
        mbRec.classList.add("is-rec");
        status.textContent = d.ai && !d.quiet ? "✦ " + pick(d.mode) : "";
      });
      later(t0 + rec, function () {
        phase = "proc";
        mbRec.classList.remove("is-rec");
        widget.classList.add("is-processing");
        status.textContent = t("Transkrybuję…", "Transcribing…");
      });
      var proc = 450;
      if (d.ai) {
        later(t0 + rec + proc, function () { status.textContent = t("Poprawiam z AI · ", "Polishing with AI · ") + pick(d.mode); });
        proc += 800;
      }
      later(t0 + rec + proc, function () {
        phase = "done";
        widget.classList.remove("is-on");
        paste(id);
      });
      later(t0 + rec + proc + 400, function () { widget.classList.remove("is-processing"); status.textContent = ""; });
      if (auto) later(t0 + rec + proc + 3800, function () {
        if (running) play(order[(order.indexOf(id) + 1) % order.length]);
      });
    }
    function tick(now) {
      if (!running) { loopOn = false; return; }
      var time = now / 1000, d = DESK[current];
      if (phase === "rec") {
        var s = Math.min(d.secs, Math.floor((now - recStart) / 1000 * d.secs / 3));
        timer.textContent = "00:" + (s < 10 ? "0" : "") + s;
        paintWave(bars, speech(time), time);
      } else if (phase === "proc") paintWave(bars, 0.18, time * 0.5);
      else { timer.textContent = "00:00"; paintWave(bars, 0.2, time); }
      requestAnimationFrame(tick);
    }
    function start() {
      if (running || !visible || document.hidden) return;
      if (calm.matches) { finalState(current); return; }
      running = true;
      if (!loopOn) { loopOn = true; requestAnimationFrame(tick); }
      play(current);
    }
    function stop() { running = false; clear(); }

    tabs.forEach(function (b, i) {
      function go(tab, focus) {
        var id = tab.getAttribute("aria-controls").replace("app-", "");
        auto = false;
        if (focus) tab.focus();
        if (calm.matches) { finalState(id); return; }
        current = id;
        if (running) play(id); else { show(id); resetTarget(id); }
      }
      b.addEventListener("click", function () { go(b); });
      b.addEventListener("keydown", function (e) {
        var dd = e.key === "ArrowRight" || e.key === "ArrowDown" ? 1 : e.key === "ArrowLeft" || e.key === "ArrowUp" ? -1 : 0;
        if (!dd) return;
        e.preventDefault();
        go(tabs[(i + dd + tabs.length) % tabs.length], true);
      });
    });
    if ("IntersectionObserver" in window) {
      new IntersectionObserver(function (es) {
        visible = es[0].isIntersecting;
        if (visible) start(); else stop();
      }, { threshold: 0.3 }).observe(desk);
    } else { visible = true; }
    document.addEventListener("visibilitychange", function () { if (document.hidden) stop(); else start(); });
    onLang.push(function () {
      if (calm.matches) { finalState(current); return; }
      if (running) play(current); else { show(current); resetTarget(current); }
    });
    paintWave(bars, 0.2, 0);
    if (calm.matches) finalState(current); else { show(current); resetTarget(current); start(); }
  })();

  /* ------------------------------------------------------------ stories: opinions as photo / video stories */
  var storiesEl = document.getElementById("opinie");
  if (storiesEl && window.fetch) (function () {
    var demo = /[?&]stories=demo\b/.test(location.search);
    var track = document.getElementById("stories-track");
    var viewer = document.getElementById("story-viewer");
    var $ = function (id) { return document.getElementById(id); };
    var svMedia = $("sv-media"), svBars = $("sv-bars"), svAv = $("sv-av"), svName = $("sv-name"), svRole = $("sv-role"), svQuote = $("sv-quote");
    var svSound = $("sv-sound"), svClose = $("sv-close"), svPrev = $("sv-prev"), svNext = $("sv-next");
    var arrows = storiesEl.querySelectorAll(".st-arrow");
    var list = [], idx = 0, raf = 0, elapsed = 0, last = 0, muted = true, lastFocus = null, cardIO = null;
    var IMAGE_MS = 6000;
    var PLAY = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7 4.5v15l13-7.5z" fill="currentColor"/></svg>';

    function L(v) { return v && typeof v === "object" ? (lang === "en" ? v.en || v.pl : v.pl || v.en) || "" : v || ""; }
    function initials(n) { return String(n).split(/\s+/).map(function (s) { return s.charAt(0); }).join("").slice(0, 2).toUpperCase(); }
    function avatar(el, s) {
      if (s.avatar) { el.style.backgroundImage = 'url("' + s.avatar + '")'; el.textContent = ""; }
      else { el.style.backgroundImage = ""; el.textContent = initials(L(s.name)); }
    }
    function el(tag, cls, text) { var e = document.createElement(tag); if (cls) e.className = cls; if (text) e.textContent = text; return e; }

    function render() {
      track.innerHTML = "";
      list.forEach(function (s, i) {
        var li = el("li"), b = el("button", "story");
        b.type = "button";
        b.setAttribute("aria-label", L(s.name) + ": " + L(s.quote));
        var m;
        if (s.type === "video") {
          m = el("video");
          m.muted = true; m.loop = true; m.playsInline = true; m.preload = "metadata";
          m.setAttribute("muted", ""); m.setAttribute("playsinline", "");
          if (s.poster) m.poster = s.poster;
          m.src = s.src;
        } else {
          m = el("img"); m.src = s.src; m.alt = ""; m.loading = "lazy"; m.decoding = "async";
        }
        m.setAttribute("aria-hidden", "true");
        b.appendChild(m);
        var top = el("span", "st-top"), ring = el("span", "st-ring"), av = el("span", "st-av"), who = el("span", "st-who");
        avatar(av, s);
        ring.appendChild(av);
        who.appendChild(el("b", "", L(s.name)));
        if (L(s.role)) who.appendChild(el("span", "", L(s.role)));
        top.appendChild(ring); top.appendChild(who);
        if (s.type === "video") { var k = el("span", "st-kind"); k.innerHTML = PLAY; top.appendChild(k); }
        b.appendChild(top);
        if (demo) b.appendChild(el("span", "st-sample", t("Podgląd układu", "Layout preview")));
        else if (L(s.label)) b.appendChild(el("span", "st-sample", L(s.label)));
        if (L(s.quote)) b.appendChild(el("span", "st-quote" + (s.label ? " plain" : ""), L(s.quote)));
        b.addEventListener("click", function () { open(i, b); });
        li.appendChild(b);
        track.appendChild(li);
      });
      watchVideos();
      updateArrows();
    }

    /* card videos play muted only while on screen */
    function watchVideos() {
      if (cardIO) cardIO.disconnect();
      var vids = track.querySelectorAll("video");
      if (!vids.length || !("IntersectionObserver" in window)) return;
      cardIO = new IntersectionObserver(function (es) {
        es.forEach(function (e) {
          if (e.isIntersecting && !calm.matches && viewer.hidden) { var p = e.target.play(); if (p && p.catch) p.catch(function () {}); }
          else e.target.pause();
        });
      }, { threshold: 0.5 });
      vids.forEach(function (v) { cardIO.observe(v); });
    }

    /* the arrows move by as many whole cards as fit, so a snap point is always the target */
    function step() {
      var c = track.querySelector("li");
      if (!c) return 300;
      var w = c.getBoundingClientRect().width + 16;
      return Math.max(1, Math.floor((track.clientWidth - 32) / w)) * w;
    }

    /* mouse drag (touch and trackpads scroll natively); a drag never opens a story */
    var drag = null, dragged = false;
    track.addEventListener("pointerdown", function (e) {
      if (e.pointerType !== "mouse" || e.button !== 0) return;
      drag = { x: e.clientX, left: track.scrollLeft, id: e.pointerId };
      dragged = false;
    });
    track.addEventListener("pointermove", function (e) {
      if (!drag || e.pointerId !== drag.id) return;
      var dx = e.clientX - drag.x;
      if (!dragged && Math.abs(dx) > 5) {
        dragged = true;
        track.classList.add("is-dragging");
        track.setPointerCapture(drag.id);
      }
      if (dragged) track.scrollLeft = drag.left - dx;
    });
    function endDrag() {
      if (!drag) return;
      drag = null;
      if (!dragged) return;
      /* glide to the nearest card, then give the snapping back to the browser */
      var li = track.querySelector("li"), w = li ? li.offsetWidth + 16 : 1;
      track.scrollTo({ left: Math.round(track.scrollLeft / w) * w, behavior: calm.matches ? "auto" : "smooth" });
      setTimeout(function () { track.classList.remove("is-dragging"); }, calm.matches ? 0 : 450);
    }
    track.addEventListener("pointerup", endDrag);
    track.addEventListener("pointercancel", endDrag);
    track.addEventListener("click", function (e) { if (dragged) { e.preventDefault(); e.stopPropagation(); dragged = false; } }, true);
    track.addEventListener("dragstart", function (e) { e.preventDefault(); });
    track.addEventListener("keydown", function (e) {
      if (e.key !== "ArrowRight" && e.key !== "ArrowLeft") return;
      var cards = Array.prototype.slice.call(track.querySelectorAll(".story")), i = cards.indexOf(document.activeElement);
      if (i < 0) return;
      e.preventDefault();
      var n = cards[Math.min(cards.length - 1, Math.max(0, i + (e.key === "ArrowRight" ? 1 : -1)))];
      n.focus({ preventScroll: true });
      n.scrollIntoView({ inline: "nearest", block: "nearest", behavior: calm.matches ? "auto" : "smooth" });
    });
    function updateArrows() {
      var max = track.scrollWidth - track.clientWidth - 2;
      arrows[0].disabled = track.scrollLeft <= 2;
      arrows[1].disabled = track.scrollLeft >= max;
    }
    arrows.forEach(function (a) {
      a.addEventListener("click", function () {
        track.scrollBy({ left: Number(a.dataset.dir) * step(), behavior: calm.matches ? "auto" : "smooth" });
      });
    });
    track.addEventListener("scroll", updateArrows, { passive: true });
    window.addEventListener("resize", updateArrows);

    /* the full-screen viewer */
    function current() { return svMedia.querySelector("video"); }
    function fill(i) {
      var s = list[i];
      avatar(svAv, s);
      svName.textContent = L(s.name);
      svRole.textContent = L(s.role) + (L(s.label) ? " · " + L(s.label) : "");
      svQuote.textContent = L(s.quote);
      if (s.link) {
        var a = el("a", "", t("Zobacz profil", "View profile"));
        a.href = s.link; a.target = "_blank"; a.rel = "noopener";
        svQuote.appendChild(document.createElement("br"));
        svQuote.appendChild(a);
      }
    }
    function show(i) {
      idx = i;
      var s = list[i];
      svBars.innerHTML = "";
      list.forEach(function (_, k) { var bar = el("i", k < i ? "done" : ""); bar.appendChild(el("b")); svBars.appendChild(bar); });
      fill(i);
      svMedia.innerHTML = "";
      if (s.type === "video") {
        var v = el("video");
        v.playsInline = true; v.setAttribute("playsinline", ""); v.muted = muted; v.autoplay = true;
        if (s.poster) v.poster = s.poster;
        v.src = s.src;
        v.addEventListener("ended", next);
        svMedia.appendChild(v);
        var p = v.play(); if (p && p.catch) p.catch(function () { v.muted = true; muted = true; syncSound(); v.play().catch(function () {}); });
        svSound.hidden = false;
      } else {
        var img = el("img"); img.src = s.src; img.alt = "";
        svMedia.appendChild(img);
        svSound.hidden = true;
      }
      syncSound();
      elapsed = 0; last = performance.now();
      cancelAnimationFrame(raf);
      raf = requestAnimationFrame(tick);
    }
    function tick(now) {
      if (viewer.hidden) return;
      var bar = svBars.children[idx] && svBars.children[idx].firstChild, v = current(), p;
      if (v) p = v.duration ? v.currentTime / v.duration : 0;
      else { elapsed += Math.min(now - last, 100); p = elapsed / IMAGE_MS; }
      last = now;
      if (bar) bar.style.width = Math.min(100, p * 100) + "%";
      if (!v && p >= 1) { next(); return; }
      raf = requestAnimationFrame(tick);
    }
    function next() { if (idx < list.length - 1) show(idx + 1); else close(); }
    function prev() { show(Math.max(0, idx - 1)); }
    function syncSound() { svSound.setAttribute("aria-pressed", String(!muted)); }
    function open(i, from) {
      lastFocus = from;
      track.querySelectorAll("video").forEach(function (v) { v.pause(); });
      viewer.hidden = false;
      root.style.overflow = "hidden";
      show(i);
      svClose.focus();
    }
    function close() {
      cancelAnimationFrame(raf);
      var v = current(); if (v) v.pause();
      svMedia.innerHTML = "";
      viewer.hidden = true;
      root.style.overflow = "";
      watchVideos();
      if (lastFocus) lastFocus.focus();
    }
    svNext.addEventListener("click", next);
    svPrev.addEventListener("click", prev);
    svClose.addEventListener("click", close);
    svSound.addEventListener("click", function () { muted = !muted; var v = current(); if (v) v.muted = muted; syncSound(); });
    viewer.addEventListener("click", function (e) { if (e.target === viewer) close(); });
    viewer.addEventListener("keydown", function (e) {
      if (e.key === "Escape") { e.preventDefault(); close(); }
      else if (e.key === "ArrowRight") { e.preventDefault(); next(); }
      else if (e.key === "ArrowLeft") { e.preventDefault(); prev(); }
      else if (e.key === "Tab") {
        var f = Array.prototype.filter.call(viewer.querySelectorAll("button,a[href]"), function (x) { return !x.hidden && x.offsetParent !== null; });
        if (!f.length) return;
        var first = f[0], lastEl = f[f.length - 1];
        if (e.shiftKey && document.activeElement === first) { e.preventDefault(); lastEl.focus(); }
        else if (!e.shiftKey && document.activeElement === lastEl) { e.preventDefault(); first.focus(); }
      }
    });

    /* the file may carry its own title and lead ({"title", "lead", "items"}), so the copy can say
       "illustrations" now and "opinions" once real ones arrive, without touching the HTML */
    var copy = null;
    function applyCopy() {
      if (!copy) return;
      var h = $("stories-title"), p = storiesEl.querySelector(".head p");
      if (copy.title) { h.textContent = L(copy.title); h.removeAttribute("data-en"); }
      if (copy.lead && p) { p.textContent = L(copy.lead); p.removeAttribute("data-en"); }
    }
    onLang.push(function () { if (!list.length) return; applyCopy(); render(); if (!viewer.hidden) fill(idx); });

    fetch(demo ? "assets/stories/stories-demo.json" : "assets/stories/stories.json", { cache: "no-cache" })
      .then(function (r) { return r.ok ? r.json() : []; })
      .then(function (data) {
        var items = Array.isArray(data) ? data : data && Array.isArray(data.items) ? data.items : [];
        if (!Array.isArray(data) && data) copy = { title: data.title, lead: data.lead };
        list = items.filter(function (s) { return s && s.src; });
        if (!list.length) return;
        applyCopy();
        storiesEl.hidden = false;
        render();
      })
      .catch(function () {});
  })();

  /* ------------------------------------------------------------ tabs (the app tour) */
  document.querySelectorAll('[role="tablist"]:not(.dock-tabs)').forEach(function (list) {
    var tabs = Array.prototype.slice.call(list.querySelectorAll('[role="tab"]'));
    function select(tab, focus) {
      tabs.forEach(function (x) {
        var on = x === tab;
        x.setAttribute("aria-selected", String(on));
        x.tabIndex = on ? 0 : -1;
        var p = document.getElementById(x.getAttribute("aria-controls"));
        if (p) p.hidden = !on;
      });
      if (focus) tab.focus();
    }
    tabs.forEach(function (tab, i) {
      tab.addEventListener("click", function () { select(tab); });
      tab.addEventListener("keydown", function (e) {
        var d = e.key === "ArrowRight" || e.key === "ArrowDown" ? 1 : e.key === "ArrowLeft" || e.key === "ArrowUp" ? -1 : 0;
        if (e.key === "Home") { e.preventDefault(); select(tabs[0], true); return; }
        if (e.key === "End") { e.preventDefault(); select(tabs[tabs.length - 1], true); return; }
        if (!d) return;
        e.preventDefault();
        select(tabs[(i + d + tabs.length) % tabs.length], true);
      });
    });
  });

  /* ------------------------------------------------------------ pricing period */
  var pricing = document.querySelector(".pricing");
  if (pricing) {
    var periods = pricing.querySelectorAll(".billing button");
    periods.forEach(function (b) {
      b.addEventListener("click", function () {
        pricing.dataset.billing = b.dataset.period;
        periods.forEach(function (x) { x.setAttribute("aria-pressed", String(x === b)); });
      });
    });
  }

  /* ------------------------------------------------------------ the typing race fills once, when it is seen */
  var race = document.getElementById("race");
  if (race) {
    if (calm.matches || !("IntersectionObserver" in window)) race.classList.add("is-in");
    else {
      var rio = new IntersectionObserver(function (es) {
        if (es[0].isIntersecting) { race.classList.add("is-in"); rio.disconnect(); }
      }, { threshold: 0.5 });
      rio.observe(race);
    }
  }

  /* ------------------------------------------------------------ the self-learning card plays once, when it is seen */
  var learn = document.getElementById("learn");
  if (learn && !calm.matches && "IntersectionObserver" in window) {
    learn.classList.add("will-play");
    var lio = new IntersectionObserver(function (es) {
      if (es[0].isIntersecting) { learn.classList.add("is-in"); lio.disconnect(); }
    }, { threshold: 0.4 });
    lio.observe(learn);
  }

  /* ------------------------------------------------------------ start in the saved language */
  var saved = null;
  try { saved = localStorage.getItem("captylo-lang"); } catch (e) {}
  if (!saved && /^en\b/i.test(navigator.language || "") && !/^pl\b/i.test(navigator.language || "")) saved = null;
  if (saved === "en") setLang("en");
})();
