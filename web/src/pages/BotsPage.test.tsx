// @vitest-environment jsdom
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { MemoryRouter } from "react-router";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { profileScopeForChat } from "./BotsPage";

vi.mock("@/lib/api", () => ({
  api: {
    getProfiles: vi.fn(async () => ({
      profiles: [
        {
          name: "default",
          path: "/tmp/default",
          is_default: true,
          model: "openrouter/auto",
          provider: "openrouter",
          has_env: true,
          skill_count: 1,
          gateway_running: false,
          description: "Main agent",
          description_auto: false,
          distribution_name: null,
          distribution_version: null,
          distribution_source: null,
          has_alias: false,
        },
        {
          name: "researcher",
          path: "/tmp/researcher",
          is_default: false,
          model: null,
          provider: null,
          has_env: false,
          skill_count: 0,
          gateway_running: false,
          description: "",
          description_auto: false,
          distribution_name: null,
          distribution_version: null,
          distribution_source: null,
          has_alias: false,
        },
      ],
    })),
  },
}));

vi.mock("@/contexts/useProfileScope", () => ({
  useProfileScope: () => ({
    profile: "",
    currentProfile: "default",
    profiles: ["default", "researcher"],
    setProfile: vi.fn(),
  }),
}));

vi.mock("@/contexts/usePageHeader", () => ({
  usePageHeader: () => ({
    setEnd: vi.fn(),
    setAfterTitle: vi.fn(),
    setTitle: vi.fn(),
  }),
}));

vi.mock("@/plugins", () => ({
  PluginSlot: () => null,
}));

function I18nStub({ children }: { children: ReactNode }) {
  return children;
}

vi.mock("@/i18n", () => ({
  useI18n: () => ({ t: {} }),
  I18nProvider: I18nStub,
}));

describe("profileScopeForChat", () => {
  it("leaves the dashboard default unscoped and names every other bot", () => {
    expect(profileScopeForChat("default")).toBe("");
    expect(profileScopeForChat("researcher")).toBe("researcher");
  });
});

describe("BotsPage", () => {
  let container: HTMLDivElement;
  let root: Root;

  beforeEach(() => {
    container = document.createElement("div");
    document.body.appendChild(container);
    root = createRoot(container);
  });

  afterEach(() => {
    act(() => {
      root.unmount();
    });
    container.remove();
  });

  it("lists each profile as a bot and points at Keys for OpenRouter", async () => {
    const { default: BotsPage } = await import("./BotsPage");
    await act(async () => {
      root.render(
        <MemoryRouter>
          <BotsPage />
        </MemoryRouter>,
      );
    });
    await act(async () => {
      await Promise.resolve();
    });
    expect(container.textContent).toMatch(/default/);
    expect(container.textContent).toMatch(/researcher/);
    expect(container.textContent).toMatch(/OPENROUTER_API_KEY/);
    expect(container.textContent).toMatch(/Chat/);
  });
});
