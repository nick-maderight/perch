EMACS ?= emacs

.PHONY: test test-unit compile clean

test:
	$(EMACS) -Q --batch -L . -l tests/perch-dictate-test.el -f ert-run-tests-batch-and-exit

test-unit:
	$(EMACS) -Q --batch -L . -l tests/perch-dictate-test.el --eval '(ert-run-tests-batch-and-exit (quote (not (tag :integration))))'

compile:
	$(EMACS) -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile perch-dictate.el
	rm -f perch-dictate.elc

clean:
	rm -f perch-dictate.elc
	rm -rf .deps
