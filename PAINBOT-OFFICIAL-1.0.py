import os
import discord
from discord.ext import commands

TOKEN = os.getenv("PAINBOT_TOKEN", "PUT_YOUR_BOT_TOKEN_HERE")

intents = discord.Intents.default()
intents.message_content = True
intents.members = True
intents.voice_states = True

bot = commands.Bot(command_prefix="!", intents=intents, help_command=None)

CATEGORIES = {
    "🎵 Music": [
        "`!join` — Join voice",
        "`!leave` — Leave voice",
        "`!play <query>` — Play/request a track",
        "`!pause` — Pause",
        "`!resume` — Resume",
        "`!skip` — Skip",
        "`!stop` — Stop",
        "`!queue` — Queue",
        "`!shuffle` — Shuffle",
        "`!loop` — Toggle loop",
        "`!volume <1-100>` — Volume",
        "`!nowplaying` — Current track",
    ],
    "🛡️ Moderation": [
        "`!ban @user [reason]`",
        "`!kick @user [reason]`",
        "`!timeout @user <minutes>`",
        "`!purge <amount>`",
        "`!lock` / `!unlock`",
    ],
    "🎫 Tickets": [
        "`!ticket` — Ticket panel",
        "Create / Close buttons",
    ],
    "🔧 Utility": [
        "`!ping`",
        "`!userinfo [@user]`",
        "`!serverinfo`",
        "`!avatar [@user]`",
        "`!botinfo`",
    ],
}

class HelpSelect(discord.ui.Select):
    def __init__(self):
        options = [discord.SelectOption(label=k, value=k) for k in CATEGORIES]
        super().__init__(placeholder="Select a category...", options=options)

    async def callback(self, interaction):
        cat = self.values[0]
        embed = discord.Embed(
            title=f"🤖 PainBot — {cat}",
            description="\n".join(CATEGORIES[cat]),
            color=discord.Color.blurple(),
        )
        await interaction.response.edit_message(embed=embed, view=self.view)

class HelpView(discord.ui.View):
    def __init__(self):
        super().__init__(timeout=180)
        self.add_item(HelpSelect())

    @discord.ui.button(label="Home", emoji="🏠", style=discord.ButtonStyle.secondary)
    async def home(self, interaction, button):
        embed = discord.Embed(
            title="🤖 PainBot — All in One",
            description="Select a category below to view commands.",
            color=discord.Color.blurple(),
        )
        await interaction.response.edit_message(embed=embed, view=HelpView())

@bot.command()
async def help(ctx):
    embed = discord.Embed(
        title="🤖 PainBot — All in One",
        description="Select a category below to view commands.",
        color=discord.Color.blurple(),
    )
    await ctx.send(embed=embed, view=HelpView())

@bot.command()
async def ping(ctx):
    await ctx.send(f"🏓 Pong! `{round(bot.latency * 1000)}ms`")

@bot.command()
async def botinfo(ctx):
    await ctx.send(embed=discord.Embed(
        title="🤖 PainBot",
        description="**All in One Discord Bot**\nPrefix: `!`",
        color=discord.Color.blurple(),
    ))

@bot.command()
async def serverinfo(ctx):
    g = ctx.guild
    e = discord.Embed(title=f"🏠 {g.name}", color=discord.Color.blurple())
    e.add_field(name="Members", value=g.member_count)
    e.add_field(name="Channels", value=len(g.channels))
    await ctx.send(embed=e)

@bot.command()
async def userinfo(ctx, member: discord.Member = None):
    member = member or ctx.author
    e = discord.Embed(title=f"👤 {member}", color=discord.Color.blurple())
    e.add_field(name="ID", value=member.id)
    await ctx.send(embed=e)

@bot.command()
async def avatar(ctx, member: discord.Member = None):
    member = member or ctx.author
    if member.avatar:
        e = discord.Embed(title=f"🖼️ {member}'s Avatar")
        e.set_image(url=member.avatar.url)
        await ctx.send(embed=e)
    else:
        await ctx.send("No custom avatar.")

@bot.command()
@commands.has_permissions(ban_members=True)
async def ban(ctx, member: discord.Member, *, reason="No reason provided"):
    await member.ban(reason=reason)
    await ctx.send(f"🔨 **{member}** banned. Reason: {reason}")

@bot.command()
@commands.has_permissions(kick_members=True)
async def kick(ctx, member: discord.Member, *, reason="No reason provided"):
    await member.kick(reason=reason)
    await ctx.send(f"👢 **{member}** kicked. Reason: {reason}")

@bot.command()
@commands.has_permissions(manage_messages=True)
async def purge(ctx, amount: int):
    if not 1 <= amount <= 100:
        return await ctx.send("Amount must be 1-100.")
    deleted = await ctx.channel.purge(limit=amount + 1)
    await ctx.send(f"🧹 Deleted {len(deleted)-1} messages.", delete_after=3)

@bot.command()
@commands.has_permissions(manage_channels=True)
async def lock(ctx):
    ow = ctx.channel.overwrites_for(ctx.guild.default_role)
    ow.send_messages = False
    await ctx.channel.set_permissions(ctx.guild.default_role, overwrite=ow)
    await ctx.send("🔒 Channel locked.")

@bot.command()
@commands.has_permissions(manage_channels=True)
async def unlock(ctx):
    ow = ctx.channel.overwrites_for(ctx.guild.default_role)
    ow.send_messages = True
    await ctx.channel.set_permissions(ctx.guild.default_role, overwrite=ow)
    await ctx.send("🔓 Channel unlocked.")

# Music command/UI layer. Real audio playback needs FFmpeg plus an audio backend/node.
music = {}

def state(g):
    return music.setdefault(g.id, {"queue": [], "loop": False, "volume": 100})

@bot.command()
async def join(ctx):
    if not ctx.author.voice:
        return await ctx.send("❌ Join a voice channel first.")
    ch = ctx.author.voice.channel
    if ctx.voice_client:
        await ctx.voice_client.move_to(ch)
    else:
        await ch.connect()
    await ctx.send(f"🎵 Joined **{ch.name}**.")

@bot.command()
async def leave(ctx):
    if ctx.voice_client:
        await ctx.voice_client.disconnect()
        music.pop(ctx.guild.id, None)
        await ctx.send("👋 Left the voice channel.")
    else:
        await ctx.send("❌ I'm not in a voice channel.")

@bot.command()
async def play(ctx, *, query):
    state(ctx.guild).setdefault("queue", []).append(query)
    if not ctx.voice_client and ctx.author.voice:
        await ctx.author.voice.channel.connect()
    await ctx.send(f"🎵 Added to queue: **{discord.utils.escape_markdown(query)}**\n"
                   "ℹ️ Install/configure an audio backend for actual playback.")

@bot.command()
async def pause(ctx):
    if ctx.voice_client and ctx.voice_client.is_playing():
        ctx.voice_client.pause()
        await ctx.send("⏸️ Paused.")
    else:
        await ctx.send("❌ Nothing is playing.")

@bot.command()
async def resume(ctx):
    if ctx.voice_client and ctx.voice_client.is_paused():
        ctx.voice_client.resume()
        await ctx.send("▶️ Resumed.")
    else:
        await ctx.send("❌ Nothing is paused.")

@bot.command()
async def skip(ctx):
    if ctx.voice_client and (ctx.voice_client.is_playing() or ctx.voice_client.is_paused()):
        ctx.voice_client.stop()
        await ctx.send("⏭️ Skipped.")
    else:
        await ctx.send("❌ Nothing is playing.")

@bot.command()
async def stop(ctx):
    if ctx.voice_client:
        ctx.voice_client.stop()
    state(ctx.guild)["queue"].clear()
    await ctx.send("⏹️ Stopped and cleared queue.")

@bot.command()
async def queue(ctx):
    q = state(ctx.guild)["queue"]
    await ctx.send("📋 Queue is empty." if not q else "\n".join(f"`{i}.` {x}" for i, x in enumerate(q[:20], 1)))

@bot.command()
async def shuffle(ctx):
    import random
    random.shuffle(state(ctx.guild)["queue"])
    await ctx.send("🔀 Queue shuffled.")

@bot.command()
async def loop(ctx):
    s = state(ctx.guild)
    s["loop"] = not s["loop"]
    await ctx.send(f"🔁 Loop: **{'ON' if s['loop'] else 'OFF'}**")

@bot.command()
async def volume(ctx, value: int):
    if not 1 <= value <= 100:
        return await ctx.send("❌ Volume must be 1-100.")
    state(ctx.guild)["volume"] = value
    await ctx.send(f"🔊 Volume set to **{value}%**.")

@bot.command()
async def nowplaying(ctx):
    await ctx.send("🎵 **Now Playing:** Audio backend not configured.")

@bot.command()
@commands.has_permissions(manage_channels=True)
async def ticket(ctx):
    e = discord.Embed(
        title="🎫 PainBot Support",
        description="Use the button below to create a ticket.",
        color=discord.Color.blurple(),
    )
    v = discord.ui.View(timeout=300)

    async def create(interaction):
        existing = discord.utils.get(ctx.guild.text_channels, name=f"ticket-{interaction.user.id}")
        if existing:
            return await interaction.response.send_message(
                f"❌ You already have {existing.mention}.", ephemeral=True
            )
        overwrites = {
            ctx.guild.default_role: discord.PermissionOverwrite(view_channel=False),
            interaction.user: discord.PermissionOverwrite(view_channel=True, send_messages=True),
        }
        ch = await ctx.guild.create_text_channel(
            f"ticket-{interaction.user.id}", overwrites=overwrites
        )
        await ch.send(f"🎫 Ticket opened for {interaction.user.mention}.")
        await interaction.response.send_message(f"✅ Created {ch.mention}.", ephemeral=True)

    b = discord.ui.Button(label="Create Ticket", emoji="🎫", style=discord.ButtonStyle.green)
    b.callback = create
    v.add_item(b)
    await ctx.send(embed=e, view=v)

@bot.event
async def on_ready():
    print(f"PainBot online: {bot.user} | Servers: {len(bot.guilds)}")

@bot.event
async def on_command_error(ctx, error):
    if isinstance(error, commands.CommandNotFound):
        return
    if isinstance(error, commands.MissingPermissions):
        return await ctx.send("❌ You don't have permission to use this command.")
    if isinstance(error, commands.MissingRequiredArgument):
        return await ctx.send("❌ Missing argument. Use `!help`.")
    if isinstance(error, commands.BadArgument):
        return await ctx.send("❌ Invalid argument. Use `!help`.")
    await ctx.send(f"❌ Error: `{error}`")

if __name__ == "__main__":
    if TOKEN == "PUT_YOUR_BOT_TOKEN_HERE":
        raise SystemExit("Set PAINBOT_TOKEN before starting PainBot.")
    bot.run(TOKEN)
