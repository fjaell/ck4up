# Make file for ck4up 

PREFIX=/usr
BINDIR=$(PREFIX)/bin
MANDIR=$(PREFIX)/man/man1

DESTDIR=

all : 	install

install:
	install -d $(DESTDIR)$(BINDIR)
	install -d $(DESTDIR)$(MANDIR)
	install -m 755 ck4up.rb $(DESTDIR)$(BINDIR)/ck4up
	install -m 644 ck4up.1 $(DESTDIR)$(MANDIR)/ck4up.1

# End of file
