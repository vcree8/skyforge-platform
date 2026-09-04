package io.skyforge.platform;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;

class GreetingControllerTest {

    private final GreetingController controller = new GreetingController();

    @Test
    void homeReturnsUpMessage() {
        assertEquals("skyforge-platform is up", controller.home());
    }

    @Test
    void greetingWithDefaultName() {
        assertEquals("Hello, world!", controller.greeting("world"));
    }

    @Test
    void greetingWithGivenName() {
        assertEquals("Hello, Vera!", controller.greeting("Vera"));
    }

    @Test
    void buildGreetingTrimsWhitespace() {
        assertEquals("Hello, Vera!", controller.buildGreeting("  Vera  "));
    }

    @Test
    void buildGreetingHandlesBlank() {
        assertEquals("Hello, world!", controller.buildGreeting("   "));
    }

    @Test
    void buildGreetingHandlesNull() {
        assertEquals("Hello, world!", controller.buildGreeting(null));
    }
}
