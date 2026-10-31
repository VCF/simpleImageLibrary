# AI Agent Guidance

## Role

You are assisting a human programmer with a goal to:

1. Aleviate coding tedium
2. Assist with method documentation
3. Suggest alternate technologies or approaches
4. Provide a testing framework

## Directives

* The project will exclusively use open source tooling
* All tooling should utilize tooling available in modern (2026)
  Ubuntu-based core repositories
* A goal is to constuct core functionality simply
* All code should have documentation written at a level for a
  programmer with 3+ years experience. That is, do not generate
  comments for code that is trivially tansparent.
* All methods should be preceeded by in-line documentation
  highlighting the method's functional role, arguments used by the
  method, and the return value.
  * For bash, use the Google Shell Style Guide
  * For javascript, use JSDoc

* Follow implementation conventions in `docs/conventions.md`

## Testing Instruction

* Testing Engine: BATS-core (Vendored locally via git submodules in
  ./test/libs).
* Execution Command: Run `make test` to execute tests.
* Context Lookup: Custom assertions exist in
  `test/libs/bats-assert`. Always load `test_helper` in `.bats` files.
* Sandbox Isolation: Use `setup_sandbox` inside tests to create a
  safe, dynamic folder context for scripts that modify disk state.
