Du arbetar på min Windows-PC och ska installera och färdigställa Codex Gearbox från `https://github.com/gaffathegaffer/Codex-gearbox`. Gör arbetet själv nu, inte bara en instruktion till mig.

1. Bevara allt befintligt arbete på datorn. Kör aldrig `git reset --hard`, `git clean`, forced checkout eller något annat som kan kasta bort lokala ändringar.
2. Leta först efter en befintlig lokal checkout av `gaffathegaffer/Codex-gearbox`. Om den inte finns, klona repot till en rimlig stabil plats under min användarprofil. Om den finns, kontrollera `git status`, branch och remote och uppdatera den icke-destruktivt från `origin/main`.
3. Gå till repots rot och läs hela `AGENTS.md`, `README.md`, `CODEX_BOOTSTRAP.md` och `plugins/codex-gearbox/skills/codex-gearbox/SKILL.md`.
4. Utför därefter hela arbetsflödet i `CODEX_BOOTSTRAP.md` själv.
5. Kontrollera den verkligt installerade Codex-versionen och `codex exec --help` innan du antar CLI-syntax. GPT-5.6 kräver Codex CLI 0.144.0 eller nyare. Om versionen är äldre, identifiera hur Codex installerades på just den här datorn och uppdatera med motsvarande officiella/säkra metod utan att förstöra auth eller användarkonfiguration.
6. Kör `scripts/install.ps1` och installera Gearbox-runtime, Codex-plugin där CLI:t stöder plugin-kommandon samt båda skill-fallbacks som skriptet hanterar.
7. Kör `scripts/doctor.ps1`. Reparera konkreta installationsproblem du kan lösa lokalt. Sänk inte säkerheten till `danger-full-access` bara för att få en kontroll att bli grön.
8. Validera samtliga JSON-filer och PowerShell-skript. Kör sedan en `-DryRun` med balance-profilen så att routingtabell, min/max-klampning och konfiguration verifieras utan att någon extra modellkvot används.
9. Starta INTE ett riktigt Gearbox-jobb och kör INTE `doctor.ps1 -SmokeTest` under installationen. Jag vill bara ha allt installerat och klart.
10. Ändra inte standardprofilen från `balance`, och lämna child-sandbox på `workspace-write` om inte jag uttryckligen ber om annat.
11. Ta egna rimliga tekniska beslut utifrån datorn och repot i stället för att fråga mig om rutinval. Fråga bara om något kräver verklig extern behörighet, admin-godkännande eller information som inte går att avgöra lokalt.
12. Avsluta med en kompakt readiness-rapport med repo-path/commit, Codex-version, runtime-path, pluginstatus, skill-fallbacks, doctor-resultat, dry-run-resultat och eventuella blockers. Säg uttryckligen om jag behöver öppna en ny Codex-tråd eller starta om Codex en gång för att plugin/skill ska indexeras.
