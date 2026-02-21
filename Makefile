PREFIX = /usr
SYSCONFDIR = /etc
pkgname = atomic-upgrade

install:
	install -Dm755 bin/atomic-upgrade     $(DESTDIR)$(PREFIX)/bin/atomic-upgrade
	install -Dm755 bin/atomic-gc          $(DESTDIR)$(PREFIX)/bin/atomic-gc
	install -Dm755 bin/atomic-guard       $(DESTDIR)$(PREFIX)/bin/atomic-guard
	install -Dm755 bin/atomic-rebuild-uki $(DESTDIR)$(PREFIX)/bin/atomic-rebuild-uki
	install -Dm644 lib/atomic/common.sh   $(DESTDIR)$(PREFIX)/lib/atomic/common.sh
	install -Dm755 lib/atomic/fstab.py    $(DESTDIR)$(PREFIX)/lib/atomic/fstab.py
	install -Dm755 lib/atomic/rootdev.py  $(DESTDIR)$(PREFIX)/lib/atomic/rootdev.py
	install -Dm644 hooks/00-block-direct-upgrade.hook \
		$(DESTDIR)$(PREFIX)/share/libalpm/hooks/00-block-direct-upgrade.hook
	install -Dm755 extras/pacman-wrapper $(DESTDIR)$(PREFIX)/local/bin/pacman
	install -Dm644 LICENSE $(DESTDIR)/usr/share/licenses/$(pkgname)/LICENSE
	@if [ ! -f $(DESTDIR)$(SYSCONFDIR)/atomic.conf ]; then \
		install -Dm644 etc/atomic.conf $(DESTDIR)$(SYSCONFDIR)/atomic.conf; \
		echo "Installed default config"; \
	else \
		echo "Config exists, skipping (see etc/atomic.conf for defaults)"; \
	fi

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/atomic-upgrade
	rm -f $(DESTDIR)$(PREFIX)/bin/atomic-gc
	rm -f $(DESTDIR)$(PREFIX)/bin/atomic-guard
	rm -f $(DESTDIR)$(PREFIX)/bin/atomic-rebuild-uki
	rm -rf $(DESTDIR)$(PREFIX)/lib/atomic/
	rm -f $(DESTDIR)$(PREFIX)/share/libalpm/hooks/00-block-direct-upgrade.hook
	rm -f $(DESTDIR)$(PREFIX)/local/bin/pacman
	rm -rf $(DESTDIR)$(PREFIX)/share/licenses/$(pkgname)/
	@echo "Note: /etc/atomic.conf preserved. Remove manually if needed."

reinstall: install

install-conf:
	install -Dm644 etc/atomic.conf $(DESTDIR)$(SYSCONFDIR)/atomic.conf
