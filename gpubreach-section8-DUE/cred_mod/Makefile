obj-m += get_cred_addr.o

KDIR := /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

install:
	sudo insmod get_cred_addr.ko

uninstall:
	sudo rmmod get_cred_addr

.PHONY: all clean install uninstall
