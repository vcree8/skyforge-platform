package io.skyforge.platform;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class GreetingController {

    @GetMapping("/")
    public String home() {
        return "skyforge-platform is up";
    }

    @GetMapping("/api/greeting")
    public String greeting(@RequestParam(defaultValue = "world") String name) {
        return buildGreeting(name);
    }

    String buildGreeting(String name) {
        if (name == null || name.isBlank()) {
            return "Hello, world!";
        }
        return "Hello, " + name.trim() + "!";
    }
}
