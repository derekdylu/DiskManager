.PHONY: app run test clean

# Package into build/DiskManager.app
app:
	./scripts/build-app.sh

# Run directly during development (no packaging)
run:
	swift run DiskManager

test:
	swift test

clean:
	rm -rf .build build
