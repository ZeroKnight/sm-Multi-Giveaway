/*
 * Copyright © 2016 Alex "ZeroKnight" George
 *
 * This file is licensed under the MIT License. For details, please see the
 * LICENSE file that should be included with the source code, or
 * <https://opensource.org/licenses/MIT>
 */

#include <sourcemod>

#pragma semicolon 1
#pragma newdecls required

char PLUGIN_NAME[]    = "Multi-Giveaway";
char PLUGIN_AUTHOR[]  = "Alex \"ZeroKnight\" George";
char PLUGIN_DESC[]    = "Expansive Giveaway system with numerous types of Giveaway events and stats";
char PLUGIN_VERSION[] = "0.2.0";
char PLUGIN_URL[]     = "http:/github.com/ZeroKnight/sm-Multi-Giveaway";
char PLUGIN_TAG[]     = "[MG]";

public Plugin myinfo =
{
  name        = PLUGIN_NAME,
  author      = PLUGIN_AUTHOR,
  description = PLUGIN_DESC,
  version     = PLUGIN_VERSION,
  url         = PLUGIN_URL
};

const int MG_MAX_MESSAGE_LENGTH = 256;
const int MAX_OPTION_LENGTH = 64;

/* NOTE: (<<= 1) is actually a neat thing that SourcePawn does. It lets you
 * specify how to 'increment' each enumeration. In this case, each one will be
 * the previous value left shifted 1, which gives us our bit-field.
 */
enum Giveaway (<<= 1)
{
  GT_Invalid = -1, GT_Dice = 1, GT_Number, GT_Kill, GT_All = 7
};
const int nGiveaways = 3;

/* Global state variables/data structures */
StringMap GiveawayData;
ArrayList Dice_PlayerRolls;
ArrayList Dice_ReRolls;
ArrayList Number_PlayerGuesses;

ArrayList Current_GiveawayOpts; // NOTE: Subject to change

//File configfile = ...

// TODO: Put things like this in a personal core library?
#define CVAR(%1) ConVar cv_%1
char CVAR_PREFIX[] = "multi_giveaway";
CVAR(version);
CVAR(flags);
CVAR(enabled_giveaways);
CVAR(player_state);
CVAR(min_conn_time);
CVAR(dice_min);
CVAR(dice_max);
CVAR(dice_show_rolls);
CVAR(dice_rerolls);
CVAR(number_min);
CVAR(number_max);
CVAR(number_show_guesses);

int abs(const int i) { return (i > 0) ? i : -i; }
int min(const int i, const int k) { return (i < k) ? i : k; }
int max(const int i, const int k) { return (i > k) ? i : k; }
int clamp(const int i, const int minval, const int maxval)
{
  return max(minval, min(i, maxval));
}

void RegisterConVars()
{
  // XXX: Function overloads would be nice. Or casting that worked on strings.
  char sGT_All[32]; IntToString(view_as<int>(GT_All), sGT_All, sizeof(sGT_All));

  /* Core */
  cv_version = CreateConVar(
    "multi_giveaway_version",
    PLUGIN_VERSION,
    "Plugin version",
    FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_DONTRECORD);
  cv_flags = CreateConVar(
    "multi_giveaway_flags",
    "b",
    "List of admin flags allowed to manage giveaways");
  cv_enabled_giveaways = CreateConVar(
    "multi_giveaway_enabled_giveaways",
    sGT_All,
    "Bit-field (sum of options) of enabled Giveaways",
    FCVAR_NONE,
    true, 1.0,
    true, float(GT_All));
  cv_player_state = CreateConVar(
    "multi_giveaway_player_state",
    "2",
    "Player states eligible for Giveaway participation; each setting includes the previous one: 0 - Alive only, 1 - Dead, 2 - Spectator",
    FCVAR_NONE,
    true, 0.0,
    true, 2.0);
  cv_min_conn_time = CreateConVar( // TODO: Allow certain giveaways to override (eg. kill objective)
    "multi_giveaway_min_conn_time",
    "300", // 5 minutes
    "Amount of time in seconds a player must be connected to participate in a Giveaway",
    FCVAR_NONE,
    true, 0.0);

  /* Dice */
  cv_dice_min = CreateConVar(
    "multi_giveaway_dice_min",
    "1",
    "Lowest possible number a player may roll",
    FCVAR_NONE,
    true, 1.0);
  cv_dice_max = CreateConVar(
    "multi_giveaway_dice_max",
    "50",
    "Highest possible number a player may roll");
  cv_dice_show_rolls = CreateConVar(
    "multi_giveaway_dice_show_rolls",
    "0",
    "Who can see other clients' dice rolls: 0 - Nobody, 1 - Admins, 2 - Everyone",
    FCVAR_NONE,
    true, 0.0,
    true, 2.0);
  cv_dice_rerolls = CreateConVar(
    "multi_giveaway_dice_rerolls",
    "0",
    "Number of 'do-overs' a player gets when rolling. Only the last is counted, for better or for worse",
    FCVAR_NONE,
    true, 0.0);

  /* Number Guess */
  cv_number_min = CreateConVar(
    "multi_giveaway_number_min",
    "1",
    "Lower bound of the range of numbers",
    FCVAR_NONE,
    true, 1.0);
  cv_number_max = CreateConVar(
    "multi_giveaway_number_max",
    "100",
    "Upper bound of the range of numbers");
  cv_number_show_guesses = CreateConVar(
    "multi_giveaway_number_show_guesses",
    "2",
    "Who can see other clients' guesses: 0 - Nobody, 1 - Admins, 2 - Everyone",
    FCVAR_NONE,
    true, 0.0,
    true, 2.0);
}

void RegisterCommands()
{
  // XXX: Is there a better way to create aliases?
  // RegConsoleCmd for client commands (ie participation)
  // RegAdminCmd for admin commands (ie (start|stop)ing giveaways methodmap may
  // be helpful
  //
  // We can use AddCommandListener() to allow for "commands" that aren't
  // actually registered commands (think 'nominate')

  RegAdminCmd("sm_mg_reload", Command_ReloadConfig, ADMFLAG_CONFIG,
    "Reload configuration file");
  RegAdminCmd("sm_multigiveaway", Command_MultiGiveaway, ADMFLAG_GENERIC,
    "Manage giveaways");
  RegAdminCmd("sm_mg", Command_MultiGiveaway, ADMFLAG_GENERIC,
    "Manage giveaways");
  RegAdminCmd("sm_dice_rig", Command_Dice_Rig, ADMFLAG_CHEATS,
              "Rigs the Dice Giveaway so the chosen client wins");

  RegConsoleCmd("sm_rolldice", Command_Dice_Roll,
                "Rolls the dice during a Dice Giveaway");
  RegConsoleCmd("sm_reroll", Command_Dice_ReRoll,
                "Rolls the dice again during a Giveaway, giving you a new result (for better or worse!");
  RegConsoleCmd("sm_guess", Command_Number_Guess,
                "Guess a number for the Number-Guess Giveaway");
}

bool LoadConfig()
{
  //if (configfile != null) // is this boilerplate necessary?
    //CloseHandle(configfile);
  // ...
  return true;
}


void GetGiveawayOpts(char[] str, const int sz)
{
  char opt[64];
  for (int i = 0; i < Current_GiveawayOpts.Length; ++i)
  {
    Current_GiveawayOpts.GetString(i, opt, sizeof(opt));
    StrCat(str, sz, opt);
    StrCat(str, sz, "; ");
  }
}

void ArraySetAll(ArrayList& array, any value)
{
  for (int i = 0; i < array.Length; ++i)
    array.Set(i, value);
}

void SendToAdmins(const char[] format, any ...)
{
  char buffer[MG_MAX_MESSAGE_LENGTH];
  for (int i = 1; i <= MaxClients; ++i)
  {
    if (IsClientInGame(i) && GetUserAdmin(i) != INVALID_ADMIN_ID)
    {
      SetGlobalTransTarget(i);
      VFormat(buffer, sizeof(buffer), format, 2);
      PrintToChat(i, "%s", buffer);
    }
  }
}

/***************************************************************\
 * Giveaway Functions
\***************************************************************/

void GetGiveawayName(const Giveaway g, char[] str, const int sz)
{
  switch (g)
  {
    case GT_Invalid: return;
    case GT_Dice:    strcopy(str, sz, "Dice");
    case GT_Number:  strcopy(str, sz, "Number");
    case GT_Kill:    strcopy(str, sz, "Kill");
    default:         return;
  }
}

Giveaway GetGiveaway(const char[] name)
{
  if      (StrEqual(name, "dice", false))   return GT_Dice;
  else if (StrEqual(name, "number", false)) return GT_Number;
  else if (StrEqual(name, "kill", false))   return GT_Kill;
  else return GT_Invalid;
}

bool IsGiveawayEnabled(const Giveaway g)
{
  return view_as<Giveaway>(cv_enabled_giveaways.IntValue) & g ? true : false;
}

Giveaway GetCurrentGiveaway()
{
  Giveaway cg; GiveawayData.GetValue("Current", cg);
  return cg;
}

void SetCurrentGiveaway(const Giveaway g)
{
  GiveawayData.SetValue("Current", g);
}

bool CanParticipate(const int client)
{
  bool spectating = GetClientTeam(client) == 1;

  /* Check player state */
  if (!IsPlayerAlive(client))
  {
    char phrase[32];
    switch (cv_player_state.IntValue)
    {
      case 0:
      {
        strcopy(phrase, sizeof(phrase),
                spectating ? "MG_Ineligible_Spec" : "MG_Ineligible_Alive");
      }
      case 1:
      {
        if (spectating)
          strcopy(phrase, sizeof(phrase), "MG_Ineligible_Spec");
      }
    }
    if (strlen(phrase))
    {
      ReplyToCommand(client, "%s %t", PLUGIN_TAG, phrase);
      return false;
    }
  }

  /* Check connection time */
  float time = GetClientTime(client);
  int delta = cv_min_conn_time.IntValue - RoundToCeil(time);
  if (time < cv_min_conn_time.FloatValue)
  {
    ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Not_Connected_Long_Enough",
                   delta);
    return false;
  }
  return true;
}

bool CheckGiveaway(const Giveaway g, const int client)
{
  Giveaway cg = GetCurrentGiveaway();
  char name[32];
  GetGiveawayName(cg, name, sizeof(name));
  if (cg != g)
  {
    ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_No_Giveaway_Type", name);
    return false;
  }
  else return true;
}

bool Giveaway_Start(const Giveaway g,
                    const ArrayList opts,
                    const int client,
                    const bool restarting=false)
{
  Giveaway cg = GetCurrentGiveaway();
  char gname_current[32];
  GetGiveawayName(cg, gname_current, sizeof(gname_current));
  if (cg != GT_Invalid)
  {
    ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Giveaway_In_Progress", gname_current);
    return false;
  }

  char gname[32], opts_str[512];
  GetGiveawayName(g, gname, sizeof(gname));
  GetGiveawayOpts(opts_str, sizeof(opts_str));
  if (g == GT_Invalid)
  {
    ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Type_Invalid", gname);
    return false;
  }
  else if (!IsGiveawayEnabled(g) && !restarting)
  {
    ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Type_Disabled", gname);
    return false;
  }
  else if (g == GT_Kill) // XXX: Temporary
  {
    ReplyToCommand(client, "%s Not yet implemented!", PLUGIN_TAG);
    return false;
  }

  SetCurrentGiveaway(g);
  GiveawayData.SetValue("Participants", 0);
  GiveawayData.SetValue("Starter", client);

  if (!restarting)
  {
    ShowActivity2(client, PLUGIN_TAG, " %t", "MG_Start", gname);
    LogAction(client, -1, "%L started Giveaway \"%s\" with options: %s", client, gname, opts_str);
  }
  switch (g)
  {
    case GT_Dice:
    {
      // TODO: Allow changing of "roll" command
      PrintToChatAll("%s %t", PLUGIN_TAG, "MG_Dice_Start", "rolldice");
      if (cv_dice_rerolls.IntValue)
        PrintToChatAll("%s %t", PLUGIN_TAG, "MG_Dice_ReRoll", "reroll");
    }
    case GT_Number:
    {
      int rand = GetRandomInt(cv_number_min.IntValue, cv_number_max.IntValue);
      GiveawayData.SetValue("Number_Target", rand);
      PrintToChatAll("%s %t", PLUGIN_TAG, "MG_Number_Start", "guess", cv_number_min.IntValue, cv_number_max.IntValue);
    }
    case GT_Kill:
    {
    }
  }
  return true;
}

void Giveaway_Stop(const int client, const bool restarting=false)
{
  Giveaway cg = GetCurrentGiveaway();
  if (cg == GT_Invalid)
  {
    ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_No_Giveaway");
    return;
  }

  char gname[32];
  GetGiveawayName(cg, gname, sizeof(gname));
  if (!restarting)
  {
    ShowActivity2(client, PLUGIN_TAG, " %t", "MG_Stop", gname);
    LogAction(client, -1, "%L stopped Giveaway \"%s\"", client, gname);
  }

  int winner; GiveawayData.GetValue("Winner", winner);
  switch (cg)
  {
    case GT_Dice:
    {
      if (!restarting)
      {
        if (Dice_PlayerRolls.Length)
        {
          int bestroll = Dice_GetBestRoll();
          ArrayList tied = new ArrayList(1);
          int rigged; GiveawayData.GetValue("Winner", rigged);
          char winner_name[MAX_NAME_LENGTH];

          /* Determine whether more than 1 player has the best roll */
          for (int i = 1; i < Dice_PlayerRolls.Length; ++i)
            if (Dice_PlayerRolls.Get(i) == bestroll) tied.Push(i);

          if (tied.Length > 1)
          {
            PrintToChatAll("%s %t", PLUGIN_TAG, "MG_Giveaway_Tie");
            winner = tied.Get(GetRandomInt(0, tied.Length - 1));
          }
          else winner = tied.Get(0);

          /* Rig the Giveaway */
          if (rigged != -1) winner = rigged;

          GetClientName(winner, winner_name, sizeof(winner_name));
          PrintToChatAll("%s %t", PLUGIN_TAG,
                         bestroll == cv_dice_max.IntValue ?
                         "MG_Dice_Win_Perfect" : "MG_Dice_Win", winner_name, bestroll);
        }
        else
          PrintToChatAll("%s %t", PLUGIN_TAG, "MG_Giveaway_Cancelled", gname);
      }
      ArraySetAll(Dice_PlayerRolls, 0);
      ArraySetAll(Dice_ReRolls, cv_dice_rerolls.IntValue);
    }

    case GT_Number:
    {
      if (!restarting)
      {
        if (Number_PlayerGuesses.Length)
        {
          int target; GiveawayData.GetValue("Number_Target", target);
          char winner_name[MAX_NAME_LENGTH];

          if (winner == -1)
          {
            /* Nobody guessed bang on, so find the closest */
            int closest = Number_GetClosestGuess();
            ArrayList tied = new ArrayList(1);

            /* Determine whether more than 1 player has the closest guess */
            for (int i = 1; i < Number_PlayerGuesses.Length; ++i)
              if (Number_PlayerGuesses.Get(i) == closest) tied.Push(i);

            if (tied.Length > 1)
            {
              PrintToChatAll("%s %t", PLUGIN_TAG, "MG_Giveaway_Tie");
              winner = tied.Get(GetRandomInt(0, tied.Length - 1));
            }
            else winner = tied.Get(0);
            GetClientName(winner, winner_name, sizeof(winner_name));
            PrintToChatAll("%s %t", PLUGIN_TAG, "MG_Number_Win_Close", winner_name, closest, target);
          }
          else
          {
            GetClientName(winner, winner_name, sizeof(winner_name));
            PrintToChatAll("%s %t", PLUGIN_TAG, "MG_Number_Win", winner_name, target);
          }
        }
        else
          PrintToChatAll("%s %t", PLUGIN_TAG, "MG_Giveaway_Cancelled", gname);
      }
      ArraySetAll(Number_PlayerGuesses, 0);
    }

    case GT_Kill:
    {
    }
  }
  SetCurrentGiveaway(GT_Invalid);
  GiveawayData.SetValue("Participants", -1);
  GiveawayData.SetValue("Starter", -1);
  GiveawayData.SetValue("Winner", -1);
  Current_GiveawayOpts.Clear();
}

void Giveaway_Restart(const int client)
{
  Giveaway cg = GetCurrentGiveaway();
  if (cg == GT_Invalid)
  {
    ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_No_Giveaway");
    return;
  }

  char gname[32], opts[512];
  GetGiveawayName(cg, gname, sizeof(gname));
  GetGiveawayOpts(opts, sizeof(opts));

  ShowActivity2(client, PLUGIN_TAG, " %t", "MG_Restart", gname);
  LogAction(client, -1, "%L restarted Giveaway \"%s\" with options: %s", client, gname, opts);
  Giveaway_Stop(client, true);
  Giveaway_Start(cg, Current_GiveawayOpts, client, true);
}

void Giveaway_Status(const int client)
{
  Giveaway cg = GetCurrentGiveaway();
  if (cg == GT_Invalid)
  {
    ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_No_Giveaway");
    return;
  }

  char gname[32], opts[512];
  GetGiveawayName(cg, gname, sizeof(gname));
  GetGiveawayOpts(opts, sizeof(opts));

  ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Status", gname, opts);
  // do other things
}

void Dice_Roll(const int client, const bool rerolling=false)
{
  if (!rerolling && Dice_PlayerRolls.Get(client))
  {
    ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Dice_Rolled");
    if (cv_dice_rerolls.IntValue)
    {
      if (Dice_ReRolls.Get(client))
        ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Dice_ReRoll", "reroll");
      else
        ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Dice_ReRoll_None");
    }
    return;
  }

  int rand = GetRandomInt(cv_dice_min.IntValue, cv_dice_max.IntValue);
  int p; GiveawayData.GetValue("Participants", p);
  int rigged; GiveawayData.GetValue("Winner", rigged);

  if (!rerolling) GiveawayData.SetValue("Participants", ++p);

  // Make the rig look convincing
  if (rigged != -1 && client == rigged) rand = cv_dice_max.IntValue;

  Dice_PlayerRolls.Set(client, rand);

  char name[MAX_NAME_LENGTH];
  GetClientName(client, name, sizeof(name));
  switch (cv_dice_show_rolls.IntValue)
  {
    case 0:
    {
      ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Dice_Result", "You", rand);
    }
    case 1:
    {
      SendToAdmins("%s %t", PLUGIN_TAG, "MG_Dice_Result", name, rand);
      ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Dice_Result", name, rand);
    }
    case 2:
    {
      PrintToChatAll("%s %t", PLUGIN_TAG, "MG_Dice_Result", name, rand);
    }
  }
}

int Dice_GetBestRoll()
{
  int best = -1;
  for (int i = 1; i < Dice_PlayerRolls.Length; ++i)
  {
    int roll = Dice_PlayerRolls.Get(i);
    if (roll > best) best = roll;
  }
  return best;
}

int Number_GetClosestGuess()
{
  int closest = 0;
  int target; GiveawayData.GetValue("Number_Target", target);
  PrintToServer("target = %d", target);
  for (int i = 1; i < Number_PlayerGuesses.Length; ++i)
  {
    int guess = Number_PlayerGuesses.Get(i);
    if (guess == 0) continue; // No guess for this client
    int diff = abs(target - guess);
    int cdiff = abs(target - closest);
    if (closest == 0 || (diff < cdiff)) closest = guess;
  }
  return closest;
}

bool Number_IsGuessUnique(const int client, const int guess)
{
  for (int i = 1; i < Number_PlayerGuesses.Length; ++i)
    if (i != client && guess == Number_PlayerGuesses.Get(i)) return false;
  return true;
}

/***************************************************************\
 * SourceMod Callbacks
\***************************************************************/

public void OnPluginStart()
{
  // NOTE:
  // load our config. make use of the Kv*/KeyValue functions
  // for flag cvars, ReadFlagString(), GetUserFlagBits() and & are our friends
  // register event forwards (CreateGlobalForward())? ie kill-objectives

  RegisterCommands();
  RegisterConVars();

  /* Set up ConVar hooks */
  cv_dice_rerolls.AddChangeHook(OnConVarChange);

  char translatefile[64];
  Format(translatefile, sizeof(translatefile), "%s.phrases", PLUGIN_NAME);
  LoadTranslations(translatefile);
  LoadTranslations("common.phrases");
}

public void OnMapStart()
{
  /* Initialize global state and data structures */
  GiveawayData         = new StringMap();
  Current_GiveawayOpts     = new ArrayList(MAX_OPTION_LENGTH);
  Dice_PlayerRolls     = new ArrayList(1, MAXPLAYERS);
  Dice_ReRolls         = new ArrayList(1, MAXPLAYERS);
  Number_PlayerGuesses = new ArrayList(1, MAXPLAYERS);

  SetCurrentGiveaway(GT_Invalid);
  GiveawayData.SetValue("Participants", -1);
  GiveawayData.SetValue("Starter", -1);
  GiveawayData.SetValue("Winner", -1);

  // Dice
  ArraySetAll(Dice_PlayerRolls, 0);
  ArraySetAll(Dice_ReRolls, cv_dice_rerolls.IntValue);

  // Number Guess
  GiveawayData.SetValue("Number_Target", -1);
  ArraySetAll(Number_PlayerGuesses, 0);
}

public void OnClientDisconnect(int client)
{
  int p; GiveawayData.GetValue("Participants", p);
  int s; GiveawayData.GetValue("Starter", s);
  int w; GiveawayData.GetValue("Winner", w);
  GiveawayData.SetValue("Participants", p-1);
  if (s == client) GiveawayData.SetValue("Starter", -1);
  if (w == client) GiveawayData.SetValue("Winner", -1);

  // Dice
  Dice_PlayerRolls.Set(client, 0);

  // Number Guess
  Number_PlayerGuesses.Set(client, 0);
}

public void OnConVarChange(ConVar convar,
                           const char[] oldValue,
                           const char[] newValue)
{
  int iOld = StringToInt(oldValue);
  int iNew = StringToInt(newValue);

  if (convar == cv_dice_rerolls && iOld != iNew)
  {
    /* Change should be retroactive. Clients will get the difference added on
     * to what they have, but must be [0, new] */
    for (int i = 1; i < Dice_ReRolls.Length; ++i)
    {
      int rerolls = Dice_ReRolls.Get(i);
      int new_rerolls = max(min((iNew-iOld) + rerolls, iNew), 0);
      Dice_ReRolls.Set(i, new_rerolls);

      /* Notify players if there is a Dice Giveaway in progress */
      if ((GetCurrentGiveaway() == GT_Dice) && IsClientConnected(i))
        PrintToChat(i, "%s %t", PLUGIN_TAG, "MG_Dice_ReRoll_Changed", new_rerolls);
    }
  }
}

/***************************************************************\
 * Command Callbacks
\***************************************************************/

public Action Command_ReloadConfig(int client, int args)
{
  bool success = LoadConfig();
  LogAction(client, -1, "%s configuration reload by %L", PLUGIN_NAME, client);
  if (success)
    ShowActivity2(client, PLUGIN_TAG, " %t", "MG_Config_Reloaded");
  else // TODO: Provide error information, etc
    ShowActivity2(client, PLUGIN_TAG, " %t", "MG_Config_Error");

  return Plugin_Handled;
}

public Action Command_MultiGiveaway(int client, int args)
{
  // sm_mg [start|stop|restart|status] <dice|number|kill|...> [params]...

  if (!args)
  {
    // Interactive Mode: Menu-based interface
    ReplyToCommand(client, "%s Interactive mode not yet implemented!", PLUGIN_TAG);
    return Plugin_Handled;
  }

  char action[32], name[32];
  GetCmdArg(1, action, sizeof(action));
  GetCmdArg(2, name, sizeof(name));
  Giveaway g = GetGiveaway(name);

  if (StrEqual(action, "start", false))
  {
    if (args < 2)
    {
      /* No Giveaway specified, inform client of valid Giveaways */
      char gnames[32*nGiveaways];
      for (int i = 0; i < nGiveaways; ++i)
      {
        char gname[32];
        GetGiveawayName(view_as<Giveaway>(1<<i), gname, sizeof(gname));
        if (i != 0) StrCat(gnames, sizeof(gnames), ", ");
        StrCat(gnames, sizeof(gnames), gname);
      }
      ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Type_Needed", gnames);
      return Plugin_Handled;
    }

    for (int i = 3; i <= GetCmdArgs(); ++i)
    {
      char opt[MAX_OPTION_LENGTH];
      GetCmdArg(i, opt, sizeof(opt));
      Current_GiveawayOpts.PushString(opt);
    }
    Giveaway_Start(g, Current_GiveawayOpts, client);
  }
  else if (StrEqual(action, "stop", false))
    Giveaway_Stop(client);
  else if (StrEqual(action, "restart", false))
    Giveaway_Restart(client);
  else if (StrEqual(action, "status", false))
    Giveaway_Status(client);
  else
    ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Action_Invalid", action, "start, stop, restart, status");

  return Plugin_Handled;
}

public Action Command_Dice_Roll(int client, int args)
{
  if (!CheckGiveaway(GT_Dice, client) || !CanParticipate(client))
    return Plugin_Handled;
  Dice_Roll(client);

  return Plugin_Handled;
}

public Action Command_Dice_ReRoll(int client, int args)
{
  if (!CheckGiveaway(GT_Dice, client) || !CanParticipate(client))
    return Plugin_Handled;

  int rerolls = cv_dice_rerolls.IntValue;
  if (!rerolls)
  {
    ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Dice_ReRoll_Disabled");
    return Plugin_Handled;
  }
  if (!Dice_PlayerRolls.Get(client))
  {
    ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Dice_ReRoll_Roll_Needed");
    return Plugin_Handled;
  }

  int rolls_left = Dice_ReRolls.Get(client);
  if (rolls_left)
  {
    int last_roll = Dice_PlayerRolls.Get(client);
    Dice_Roll(client, true);
    ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Dice_ReRolled", last_roll, --rolls_left);
    Dice_ReRolls.Set(client, rolls_left);
  }
  else
    ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Dice_ReRoll_None");

  return Plugin_Handled;
}

public Action Command_Dice_Rig(int client, int args)
{
  if (!CheckGiveaway(GT_Dice, client)) return Plugin_Handled;
  if (args < 1)
  {
    ReplyToCommand(client, "%s %t", PLUGIN_TAG, "No matching client");
    return Plugin_Handled;
  }

  char arg[MAX_NAME_LENGTH], target_name[MAX_NAME_LENGTH];
  int target[1];
  bool tnml;
  GetCmdArg(1, arg, sizeof(arg));
  int rv = ProcessTargetString(arg, client, target, 1, COMMAND_FILTER_CONNECTED,
                               target_name, sizeof(target_name), tnml);
  if (rv)
  {
    ShowActivity2(client, PLUGIN_TAG, " %t", "MG_Dice_Rigged", target_name);
    GiveawayData.SetValue("Winner", target[0]);
  }
  else ReplyToTargetError(client, rv);

  return Plugin_Handled;
}

public Action Command_Number_Guess(int client, int args)
{
  if (!CheckGiveaway(GT_Number, client) || !CanParticipate(client))
    return Plugin_Handled;
  if (args < 1)
  {
    ReplyToCommand(client, "%s Usage: sm_guess <number>", PLUGIN_TAG);
    return Plugin_Handled;
  }
  else if (Number_PlayerGuesses.Get(client))
  {
    ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Number_Guessed");
    return Plugin_Handled;
  }

  int guess;
  char arg[8];
  GetCmdArg(1, arg, sizeof(arg));

  if (!StringToIntEx(arg, guess))
  {
    ReplyToCommand(client, "%s Usage: sm_guess <number>", PLUGIN_TAG);
    return Plugin_Handled;
  }
  else if (guess >= cv_number_min.IntValue && guess <= cv_number_max.IntValue)
  {
    int p; GiveawayData.GetValue("Participants", p);
    int target; GiveawayData.GetValue("Number_Target", target);

    GiveawayData.SetValue("Participants", ++p);
    Number_PlayerGuesses.Set(client, guess);
    if (guess == target)
    {
      GiveawayData.SetValue("Winner", client);
      Giveaway_Stop(0);
    }
    else if (!Number_IsGuessUnique(client, guess))
    {
      ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Number_Not_Unique");
      return Plugin_Handled;
    }
    else
    {
      char player[MAX_NAME_LENGTH];
      GetClientName(client, player, sizeof(player));
      switch (cv_number_show_guesses.IntValue)
      {
        case 0:
        {
          ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Number_Guess", "You", guess);
        }
        case 1:
        {
          SendToAdmins("%s %T", PLUGIN_TAG, "MG_Number_Guess", player, guess);
          ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Number_Guess", player, guess);
        }
        case 2:
        {
          PrintToChatAll("%s %t", PLUGIN_TAG, "MG_Number_Guess", player, guess);
        }
      }
    }
  }
  else
    ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Number_Bad_Range", cv_number_min.IntValue, cv_number_max.IntValue);

  return Plugin_Handled;
}

// vim: et sts=2 sw=2

