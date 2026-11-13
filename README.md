# sdr-skills

Agent skills for accessioning and remediating content in the Stanford Digital Repository (SDR). This is a prototype: [PLAN.md](PLAN.md) has the goals, and [DESIGN.md](DESIGN.md) has the design.

There is one skill so far, **[sdr-ops](.agents/skills/sdr-ops/SKILL.md)**: a command-line tool and Ruby library for finding objects, checking and changing versions and workflows, fetching preserved files, changing files in structural metadata, changing collection membership, registering new objects, and cloning prod objects into stage for testing. Task-specific remediation is a short script the agent generates that calls into `sdr-ops`.

## Using it

Requirements: Ruby 3.4+, the Stanford VPN, a Kerberos ticket (`kinit`), and ssh to SDR servers through `dlss-jump` (see the DeveloperPlaybook ssh setup). `login` and `find` also need ssh access as `dor_services` on the DSA hosts.

1. Install the gems:

   ```bash
   cd .agents/skills/sdr-ops && bundle install
   ```

2. Make the skill available to your agent.
   - In this repository, Claude Code finds it through `.claude/skills/sdr-ops`.
   - Elsewhere, symlink the skill into your agent's user-level skills directory:

     ```bash
     mkdir -p ~/.claude/skills && ln -s "$PWD/.agents/skills/sdr-ops" ~/.claude/skills/sdr-ops
     ```

     Other agents (e.g. Codex) have their own skills directories; check their docs.
3. Log in for the environment you'll work in. Tokens last 8 hours by default.

   ```bash
   .agents/skills/sdr-ops/bin/sdr-ops --env stage login
   ```

Run directories (ledgers, downloads, generated scripts) default to `~/sdr-ops-runs/`; set `SDR_OPS_RUNS_DIR` or pass `--run DIR` to put them elsewhere.

## Developing

```bash
cd .agents/skills/sdr-ops && bundle exec rspec && bundle exec rubocop
```

The specs run against an in-memory fake of the DSA client (`spec/support/fake_dsa.rb`) and fake shells and transports, so they need no network access. The scripts in `remote/` run on SDR servers; their specs load them with stand-ins for the server-side constants they use.

Keep `cocina-models` and `dor-services-client` in `Gemfile.lock` on the versions DSA runs: `sdr-ops whoami` warns about drift, and changes are refused until they match.
