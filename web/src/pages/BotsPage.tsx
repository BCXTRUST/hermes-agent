import { useCallback, useEffect, useLayoutEffect, useState } from "react";
import { useNavigate } from "react-router";
import { Bot, ExternalLink, MessageSquare, Plus } from "lucide-react";
import { api } from "@/lib/api";
import type { ProfileInfo } from "@/lib/api";
import { useProfileScope } from "@/contexts/useProfileScope";
import { usePageHeader } from "@/contexts/usePageHeader";
import { useToast } from "@nous-research/ui/hooks/use-toast";
import { Toast } from "@nous-research/ui/ui/components/toast";
import { Button } from "@nous-research/ui/ui/components/button";
import { Card, CardContent } from "@nous-research/ui/ui/components/card";
import { Badge } from "@nous-research/ui/ui/components/badge";
import { Spinner } from "@nous-research/ui/ui/components/spinner";
import { PluginSlot } from "@/plugins";

export const DESKTOP_BOT_MODE_DOCS =
  "https://hermes-agent.nousresearch.com/docs/user-guide/bot-mode";

export const DESKTOP_APP_DOCS =
  "https://hermes-agent.nousresearch.com/docs/user-guide/desktop";

/** Dashboard chat scopes "" for the process default profile. */
export function profileScopeForChat(name: string): string {
  return name === "default" ? "" : name;
}

/**
 * Bot Mode roster for the web dashboard.
 *
 * Official Bot Mode (Sessions | Bots tab, group rooms, @mentions, Routines
 * pane) ships in Hermes Desktop. A Bot is still just a Hermes profile, so
 * this page lists those profiles as the roster on the hosted dashboard and
 * opens each one's chat. Desktop connected to this same backend sees the
 * same Bots with the full UI.
 */
export default function BotsPage() {
  const navigate = useNavigate();
  const { setProfile } = useProfileScope();
  const { setEnd } = usePageHeader();
  const { toast, showToast } = useToast();
  const [profiles, setProfiles] = useState<ProfileInfo[] | null>(null);

  const load = useCallback(() => {
    api
      .getProfiles()
      .then((res) => setProfiles(res.profiles ?? []))
      .catch((e) => showToast(String(e), "error"));
  }, [showToast]);

  useEffect(() => {
    load();
  }, [load]);

  useLayoutEffect(() => {
    setEnd(
      <Button onClick={() => void navigate("/profiles/new")}>
        <Plus className="size-4" />
        New Agent
      </Button>,
    );
    return () => setEnd(null);
  }, [navigate, setEnd]);

  const openBotChat = (name: string) => {
    setProfile(profileScopeForChat(name));
    navigate("/chat");
  };

  return (
    <div className="flex flex-col gap-6">
      <PluginSlot name="bots:top" />
      <Toast toast={toast} />

      <Card>
        <CardContent className="flex flex-col gap-3 pt-6">
          <p className="text-sm text-muted-foreground">
            Each Bot is a Hermes profile — its own model, skills, memory, and
            chat. Create agents here, then talk to them in Chat. The full Bot
            Mode roster (group chats, @mentions, Routines) is in the{" "}
            <a
              href={DESKTOP_APP_DOCS}
              target="_blank"
              rel="noopener noreferrer"
              className="underline underline-offset-2"
            >
              Hermes Desktop
            </a>{" "}
            app: Settings → Gateways → add this dashboard as a remote gateway,
            then open the <strong>Bots</strong> tab next to Sessions.
          </p>
          <p className="text-sm text-muted-foreground">
            To make chat work, paste your OpenRouter key on{" "}
            <button
              type="button"
              className="underline underline-offset-2"
              onClick={() => navigate("/env")}
            >
              Keys
            </button>{" "}
            under <strong>OpenRouter</strong> (
            <code className="font-mono text-xs">OPENROUTER_API_KEY</code>
            ), or set that same variable on the Railway service. Then pick a
            model on the Models page.
          </p>
          <div className="flex flex-wrap gap-2">
            <Button
              outlined
              size="sm"
              onClick={() => window.open(DESKTOP_BOT_MODE_DOCS, "_blank")}
            >
              <ExternalLink className="size-3.5" />
              Bot Mode guide
            </Button>
            <Button outlined size="sm" onClick={() => navigate("/env")}>
              Open Keys
            </Button>
          </div>
        </CardContent>
      </Card>

      {profiles === null ? (
        <div className="flex items-center justify-center py-16">
          <Spinner className="text-2xl text-primary" />
        </div>
      ) : profiles.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          No agents yet. Create one with New Agent.
        </p>
      ) : (
        <ul className="grid gap-3">
          {profiles.map((p) => (
            <li key={p.name}>
              <Card>
                <CardContent className="flex flex-wrap items-center gap-3 py-4">
                  <Bot className="size-8 shrink-0 text-muted-foreground" />
                  <div className="min-w-0 flex-1">
                    <div className="flex flex-wrap items-center gap-2">
                      <span className="font-medium">
                        {p.display_name || p.name}
                      </span>
                      {p.is_default ? <Badge>default</Badge> : null}
                    </div>
                    {p.description ? (
                      <p className="mt-1 line-clamp-2 text-sm text-muted-foreground">
                        {p.description}
                      </p>
                    ) : null}
                    <p className="mt-1 font-mono text-xs text-text-tertiary">
                      {[p.provider, p.model].filter(Boolean).join(" / ") ||
                        "inherits default model"}
                    </p>
                  </div>
                  <Button onClick={() => openBotChat(p.name)}>
                    <MessageSquare className="size-4" />
                    Chat
                  </Button>
                </CardContent>
              </Card>
            </li>
          ))}
        </ul>
      )}
      <PluginSlot name="bots:bottom" />
    </div>
  );
}
