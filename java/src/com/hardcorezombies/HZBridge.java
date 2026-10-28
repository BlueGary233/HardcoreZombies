package com.hardcorezombies;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.Map;
import java.util.List;

import me.zed_0xff.zombie_buddy.Exposer;
import se.krka.kahlua.integration.annotations.LuaMethod;
import se.krka.kahlua.j2se.KahluaTableImpl;
import se.krka.kahlua.vm.KahluaTable;
import zombie.characters.IsoZombie;
import zombie.iso.IsoCell;
import zombie.iso.IsoGridSquare;
import zombie.iso.IsoMovingObject;
import zombie.iso.IsoObject;
import zombie.iso.IsoWorld;
import zombie.iso.objects.IsoDeadBody;

/**
 * HardcoreZombies Java 桥接层
 *
 * 丧尸状态只有两个字段，全部存在 modData 里，Lua 侧不存副本：
 *   hz_buff  位掩码：1=新生 2=开饭 4=饥饿 8=静音 16=受伤
 *   hz_pile  认领的尸堆 pid = floor(x)*100000 + floor(y)
 *
 * patch 层只读静音位（8）：已接单的丧尸不听本 mod 的声音。
 */
@Exposer.LuaClass
public class HZBridge {

    // ===================== buff 位掩码 =====================
    // 位：1=新生 2=开饭 4=饥饿 8=静音 16=受伤
    // Lua 侧唯一写入口是 HZ.refreshBuffs；patch 只读静音位。

    @LuaMethod(name = "HZ_setBuff", global = true)
    public static void setBuff(IsoZombie z, int bits) {
        if (z == null) return;
        try {
            if (bits == 0) z.getModData().rawset("hz_buff", null);
            else           z.getModData().rawset("hz_buff", Integer.valueOf(bits));
        } catch (Throwable t) { }
    }

    /** 认领它的堆（pid）。0 = 不在任何队列 */
    @LuaMethod(name = "HZ_setPile", global = true)
    public static void setPile(IsoZombie z, int pid) {
        if (z == null) return;
        try {
            if (pid == 0) z.getModData().rawset("hz_pile", null);
            else          z.getModData().rawset("hz_pile", Integer.valueOf(pid));
        } catch (Throwable t) { }
    }

    @LuaMethod(name = "HZ_getBuff", global = true)
    public static int getBuff(IsoZombie z) {
        return z == null ? 0 : readInt(z, "hz_buff");
    }

    @LuaMethod(name = "HZ_getPile", global = true)
    public static int getPile(IsoZombie z) {
        return z == null ? 0 : readInt(z, "hz_pile");
    }

    /**
     * 清掉丧尸的游荡/追击目标。
     * updateSearchForCorpse 的前置条件是 target != null 就清空 bodyToEat 并 return，
     * 所以派单前必须把它置空。Lua 侧既不能写字段（attempted index of non-table），
     * 也调不到 setTarget（同样报错），只能走这里。
     */
    @LuaMethod(name = "HZ_clearTarget", global = true)
    public static void clearTarget(IsoZombie z) {
        if (z == null) return;
        z.target = null;
    }

    // ===================== 性能合并 =====================
    // 下面几个方法把 Lua 侧每帧要跨 4-6 次边界的操作压成一次调用。

    /** 按 uid 在指定格子找尸体：替代 Lua 的 getCell+getGridSquare+getDeadBodys+getUID */
    @LuaMethod(name = "HZ_findBody", global = true)
    public static IsoDeadBody findBody(int x, int y, int z, String uid) {
        if (uid == null) return null;
        IsoCell cell = IsoWorld.instance == null ? null : IsoWorld.instance.getCell();
        if (cell == null) return null;
        IsoGridSquare sq = cell.getGridSquare(x, y, z);
        if (sq == null) return null;
        List<IsoDeadBody> bodies = sq.getDeadBodys();
        if (bodies == null) return null;
        for (int i = 0; i < bodies.size(); i++) {
            IsoDeadBody b = bodies.get(i);
            if (b != null && uid.equals(b.getUID())) return b;
        }
        return null;
    }

    /**
     * 订单状态位掩码，替代 Lua 里的多次调用：
     * bit0=z 已死, bit1=有 eatBodyTarget, bit2=有 bodyToEat, bit3=尸体还在世界里
     */
    @LuaMethod(name = "HZ_orderState", global = true)
    public static int orderState(IsoZombie z, IsoDeadBody body) {
        if (z == null) return 1;
        int s = 0;
        try { if (z.isDead()) s |= 1; } catch (Throwable ignored) { }
        try { if (z.getEatBodyTarget() != null) s |= 2; } catch (Throwable ignored) { }
        try { if (z.bodyToEat != null) s |= 4; } catch (Throwable ignored) { }
        try { if (body != null && body.getSquare() != null) s |= 8; } catch (Throwable ignored) { }
        return s;
    }

    /** 方形范围扫描尸体，替代 Lua 的双层循环 + 每格 getGridSquare/getDeadBodys */
    @LuaMethod(name = "HZ_scanCorpses", global = true)
    public static List<IsoDeadBody> scanCorpses(int cx, int cy, int cz, int radius) {
        ArrayList<IsoDeadBody> out = new ArrayList<>();
        IsoCell cell = IsoWorld.instance == null ? null : IsoWorld.instance.getCell();
        if (cell == null) return out;
        for (int dx = -radius; dx <= radius; dx++) {
            for (int dy = -radius; dy <= radius; dy++) {
                IsoGridSquare sq = cell.getGridSquare(cx + dx, cy + dy, cz);
                if (sq == null) continue;
                List<IsoDeadBody> bodies = sq.getDeadBodys();
                if (bodies == null) continue;
                for (int i = 0; i < bodies.size(); i++) {
                    IsoDeadBody b = bodies.get(i);
                    if (b != null && !b.isSkeleton()) out.add(b);
                }
            }
        }
        return out;
    }

    // ===================== 丧尸三维（营养系统用） =====================
    /** speedType：1=最快 3=最慢 */
    @LuaMethod(name = "HZ_getSpeedType", global = true)
    public static int getSpeedType(IsoZombie z) {
        return z == null ? 3 : z.speedType;
    }

    @LuaMethod(name = "HZ_setSpeedType", global = true)
    public static void setSpeedType(IsoZombie z, int v) {
        if (z != null) z.speedType = v;
    }

    /** strength：5 最强，1 最弱（1~5；Thump 伤害倍率） */
    @LuaMethod(name = "HZ_getStrength", global = true)
    public static int getStrength(IsoZombie z) {
        return z == null ? 1 : z.strength;
    }

    @LuaMethod(name = "HZ_setStrength", global = true)
    public static void setStrength(IsoZombie z, int v) {
        if (z != null) z.strength = v;
    }

    /** sight：1 最好，3 最差 */
    @LuaMethod(name = "HZ_getSight", global = true)
    public static int getSight(IsoZombie z) {
        return z == null ? 3 : z.sight;
    }

    @LuaMethod(name = "HZ_setSight", global = true)
    public static void setSight(IsoZombie z, int v) {
        if (z != null) z.sight = v;
    }

    /** hearing：1 最好（pinpoint），3 最差 */
    @LuaMethod(name = "HZ_getHearing", global = true)
    public static int getHearing(IsoZombie z) {
        return z == null ? 3 : z.hearing;
    }

    /** 一次性读五维 + 坐标："hp|sp|st|si|he|x|y"；失效对象返回空串 */
    @LuaMethod(name = "HZ_getStats", global = true)
    public static String getStats(IsoZombie z) {
        if (z == null) return "";
        try {
            return z.getHealth() + "|" + z.speedType + "|" + z.strength + "|"
                 + z.sight + "|" + z.hearing + "|" + z.getX() + "|" + z.getY();
        } catch (Throwable t) {
            return "";
        }
    }

    @LuaMethod(name = "HZ_setHearing", global = true)
    public static void setHearing(IsoZombie z, int v) {
        if (z != null) z.hearing = v;
    }

    /** 按格子 + UID 找僵尸（含已死）；找不到返回 null（区块卸载） */
    @LuaMethod(name = "HZ_findZombie", global = true)
    public static IsoZombie findZombie(int x, int y, int z, String uid) {
        if (uid == null) return null;
        IsoCell cell = IsoWorld.instance == null ? null : IsoWorld.instance.getCell();
        if (cell == null) return null;
        IsoGridSquare sq = cell.getGridSquare(x, y, z);
        if (sq == null) return null;
        List<IsoMovingObject> mos = sq.getMovingObjects();
        if (mos == null) return null;
        for (int i = 0; i < mos.size(); i++) {
            IsoMovingObject mo = mos.get(i);
            if (mo instanceof IsoZombie) {
                IsoZombie zb = (IsoZombie) mo;
                if (uid.equals(zb.getUID())) return zb;
            }
        }
        return null;
    }

    /** 返回引擎当前所有活动僵尸的 ArrayList（反射取 IsoCell.zombieList） */
    @LuaMethod(name = "HZ_allZombies", global = true)
    public static Object allZombies() {
        try {
            IsoCell cell = IsoWorld.instance == null ? null : IsoWorld.instance.getCell();
            if (cell == null) return null;
            java.lang.reflect.Field f = IsoCell.class.getDeclaredField("zombieList");
            f.setAccessible(true);
            return f.get(cell);
        } catch (Throwable t) {
            return null;
        }
    }

    /** 全部加载区僵尸（遍历 IsoCell.objectList，不是渲染列表） */
    @LuaMethod(name = "HZ_getAllZombies", global = true)
    public static List<IsoZombie> getAllZombies() {
        List<IsoZombie> out = new ArrayList<>();
        try {
            IsoCell cell = IsoWorld.instance == null ? null : IsoWorld.instance.getCell();
            if (cell == null) return out;
            for (IsoMovingObject o : cell.getObjectList()) {
                if (o instanceof IsoZombie) out.add((IsoZombie) o);
            }
        } catch (Throwable t) {
            // ignore
        }
        return out;
    }

    // ===================== 共享工具 =====================
    private static KahluaTable newTable() { return new KahluaTableImpl(new HashMap<Object, Object>()); }

    /** "uid|hp|sp|st|si|he"；对象已摘链读不到返回 null */
    /** 读 modData 上的 int 字段，缺失/失效一律 0 */
    private static int readInt(IsoZombie z, String key) {
        try {
            Object v = z.getModData().rawget(key);
            if (v instanceof Number) return ((Number) v).intValue();
        } catch (Throwable t) { }
        return 0;
    }

    private static String packZombie(IsoZombie z) {
        try {
            String uid = z.getUID();
            if (uid == null) return null;
            return uid + "|" + z.getHealth() + "|" + z.speedType + "|"
                 + z.strength + "|" + z.sight + "|" + z.hearing;
        } catch (Throwable t) {
            return null;
        }
    }

    // ===================== 实时快照（全量，不做 diff） =====================
    // 声音/派单每 2 秒一拍，位置表 2 拍刷新一次。调用频率低，全量比增量简单：
    //   obj[1..n]    对象，按 getObjectList() 顺序（ArrayList 保序，不是 HashMap 迭代）
    //   x[1..n] / y[1..n] / stats[1..n]（"uid|hp|sp|st|si|he"）
    //   removed[1..m] 上一批持有、本批已不在的原实例（_zstats 清理 / 订单释放）
    // 数组索引一律 Double —— Kahlua 的数字键就是 Double。

    private static final java.util.ArrayList<IsoZombie> lastFrameRefs = new java.util.ArrayList<>();
    private static boolean frameFirst = true;

    @LuaMethod(name = "HZ_zombieFrame", global = true)
    public static KahluaTable zombieFrame() {
        java.util.ArrayList<IsoZombie> objs    = new java.util.ArrayList<>();
        java.util.ArrayList<Double>    xs      = new java.util.ArrayList<>();
        java.util.ArrayList<Double>    ys      = new java.util.ArrayList<>();
        java.util.ArrayList<String>    stats   = new java.util.ArrayList<>();
        java.util.ArrayList<IsoZombie> removed = new java.util.ArrayList<>();

        java.util.IdentityHashMap<IsoZombie, Boolean> cur = new java.util.IdentityHashMap<>();
        IsoCell cell = IsoWorld.instance == null ? null : IsoWorld.instance.getCell();

        if (cell != null) {
            for (IsoMovingObject o : cell.getObjectList()) {
                if (!(o instanceof IsoZombie)) continue;
                IsoZombie zb = (IsoZombie) o;

                boolean dead = false;
                try { dead = zb.isDead(); } catch (Throwable ignored) { }
                if (dead) continue;

                String packed = packZombie(zb);
                if (packed == null) continue;

                double x, y;
                try {
                    x = zb.getX();
                    y = zb.getY();
                } catch (Throwable t) {
                    continue;
                }

                objs.add(zb);
                xs.add(x);
                ys.add(y);
                stats.add(packed);
                cur.put(zb, Boolean.TRUE);
            }
        }

        if (!frameFirst) {
            for (int i = 0; i < lastFrameRefs.size(); i++) {
                IsoZombie old = lastFrameRefs.get(i);
                if (!cur.containsKey(old)) removed.add(old);
            }
        }
        frameFirst = false;

        lastFrameRefs.clear();
        lastFrameRefs.addAll(objs);

        KahluaTable out  = newTable();
        KahluaTable tObj = newTable();
        KahluaTable tX   = newTable();
        KahluaTable tY   = newTable();
        KahluaTable tSt  = newTable();
        KahluaTable tRem = newTable();

        for (int i = 0; i < objs.size(); i++) {
            double k = (double) (i + 1);
            tObj.rawset(k, objs.get(i));
            tX.rawset(k, xs.get(i));
            tY.rawset(k, ys.get(i));
            tSt.rawset(k, stats.get(i));
        }
        for (int i = 0; i < removed.size(); i++) {
            tRem.rawset((double) (i + 1), removed.get(i));
        }

        out.rawset("obj", tObj);
        out.rawset("x", tX);
        out.rawset("y", tY);
        out.rawset("stats", tSt);
        out.rawset("removed", tRem);
        out.rawset("n", (double) objs.size());
        out.rawset("m", (double) removed.size());
        return out;
    }

    /** 读档 / 热重载：复位 diff 基线（下次返回全量） */
    @LuaMethod(name = "HZ_resetDiff", global = true)
    public static void resetDiff() {
        lastFrameRefs.clear();
        frameFirst = true;
    }

    /** 按 uid 写回五维（跨阈值成长用）；找不到对象返回 false */
    @LuaMethod(name = "HZ_applyStats", global = true)
    public static boolean applyStats(String uid, float hp, int sp, int st, int si, int he) {
        if (uid == null) return false;
        IsoCell cell = IsoWorld.instance == null ? null : IsoWorld.instance.getCell();
        if (cell == null) return false;

        for (IsoMovingObject o : cell.getObjectList()) {
            if (!(o instanceof IsoZombie)) continue;
            IsoZombie z = (IsoZombie) o;
            if (!uid.equals(z.getUID())) continue;

            try {
                z.setHealth(hp);
                // speedType 不再由五维写：速度归 modSpeedType（HZ_applyTier）管。
                // 五维里的 sp 只是营养系统的数据，写进引擎会和档位打架。
                z.strength  = st;
                z.sight     = si;
                z.hearing   = he;
                return true;
            } catch (Throwable t) {
                return false;
            }
        }
        return false;
    }

    /**
     * 装死 / 起身。
     *
     * 引擎里本来有 FakeDeadZombieState，但 B42 这个版本的 enter() 调了
     * IsoGameCharacter.setVisible(boolean)，而该版本根本没有这个方法 → 走状态机必抛异常。
     * 所以这里只做字段组合（引擎判断"假死"读的就是 fakeDead）：
     *   装死：fakeDead + onFloor + 不可碰撞       起身：三项还原
     */
    @LuaMethod(name = "HZ_fakeDead", global = true)
    public static boolean fakeDead(IsoZombie z, boolean on) {
        if (z == null) return false;
        try {
            z.setFakeDead(on);
            z.setOnFloor(on);
            z.setCollidable(!on);
            return true;
        } catch (Throwable t) {
            return false;
        }
    }

    /**
     * modSpeedType（1~4）→ 引擎对应的速度构造函数。
     *   1 慢尸 doShambler / 2 快走尸 doFastShambler / 3 跑尸 doSprinter
     *   4 假跑尸 doFakeShambler(1)：慢尸身体 + speedType=1（判定仍是跑，看着慢）
     * 只做赋值，不参与判定。
     */
    @LuaMethod(name = "HZ_applyTier", global = true)
    public static boolean applyTier(IsoZombie z, int tier) {
        if (z == null) return false;
        try {
            switch (tier) {
                case 1: z.doShambler();      return true;
                case 2: z.doFastShambler();  return true;
                case 3: z.doSprinter();      return true;
                case 4: z.doFakeShambler(1); return true;
                default: return false;
            }
        } catch (Throwable t) {
            return false;
        }
    }

    /**
     * 让这只丧尸进入"跑尸"状态。
     * 等价于引擎的 doSprinter()：speedType=1、speedMod 0.85~1.00、
     * walkVariant=ZombieWalk2、lunger=true，并同步精灵动画速率。
     * 只做赋值，不参与任何判定。
     */
    @LuaMethod(name = "HZ_applySprint", global = true)
    public static void applySprint(IsoZombie z) {
        if (z == null) return;
        // 直接调引擎自己的 doSprinter()：speedType=1、speedMod、ZombieWalk2、
        // 精灵帧速率、walkType、turnDelta 全部由引擎按原版逻辑设置。
        // 手写那几项在 def 为空时会漏掉动画，表现就是"属性对了但走不快"。
        try { z.doSprinter(); } catch (Throwable t) { }
    }

    /** 丧尸 uid -> {x,y}（仅调试 HUD 用，调用方保证只在调试模式） */
    @LuaMethod(name = "HZ_zombiePositions", global = true)
    public static KahluaTable zombiePositions() {
        KahluaTable out = newTable();
        IsoCell cell = IsoWorld.instance == null ? null : IsoWorld.instance.getCell();
        if (cell == null) return out;

        for (IsoMovingObject o : cell.getObjectList()) {
            if (!(o instanceof IsoZombie)) continue;
            IsoZombie z = (IsoZombie) o;
            String uid = z.getUID();
            if (uid == null) continue;

            KahluaTable e = newTable();
            e.rawset("x", (double) z.getX());
            e.rawset("y", (double) z.getY());
            out.rawset(uid, e);
        }
        return out;
    }
}