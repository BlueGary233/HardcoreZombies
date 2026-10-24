package com.hardcorezombies;

import java.util.List;

import me.zed_0xff.zombie_buddy.Patch;

import zombie.WorldSoundManager;
import zombie.WorldSoundManager.WorldSound;
import zombie.WorldSoundManager.ResultBiggestSound;
import zombie.characters.IsoZombie;
import zombie.iso.IsoChunk;
import zombie.iso.IsoGridSquare;
import zombie.iso.IsoUtils;
import zombie.iso.IsoWorld;
import zombie.network.GameServer;

/**
 * 替换原版的声音选择逻辑，加入"声音组"过滤。
 *
 * Lua 通过 HZ_setGroup(zombie, group) 给丧尸绑定组；
 * 发声时把 group 作为 addSound 的 source 传进来。
 * 只有同组的丧尸能听到这条声音。
 */
@Patch(className = "zombie.WorldSoundManager",
       methodName = "getBiggestSoundZomb",
       isAdvice = false,
       warmUp = true)
public class Patch_GetBiggestSoundZomb {

    private static final java.lang.reflect.Field RESULT_FIELD;

    static {
        java.lang.reflect.Field f = null;
        try {
            f = WorldSoundManager.class.getDeclaredField("resultBiggestSound");
            f.setAccessible(true);
        } catch (Throwable ignored) {}
        RESULT_FIELD = f;
    }

    private static ResultBiggestSound result(WorldSound sound, float attract) {
        try {
            if (RESULT_FIELD != null) {
                ResultBiggestSound r = (ResultBiggestSound) RESULT_FIELD.get(null);
                if (r != null) return r.init(sound, attract);
            }
        } catch (Throwable ignored) {}

        return new ResultBiggestSound().init(sound, attract);
    }

    public static ResultBiggestSound getBiggestSoundZomb(
            int x, int y, int z,
            boolean flag4,
            IsoZombie zombie) {

        float best = -1000000.0f;
        WorldSound bestSound = null;

        if (zombie != null && zombie.getCurrentSquare() == null) {
            return result(null, 0.0f);
        }

        IsoChunk chunk = (zombie != null) ? zombie.getCurrentSquare().getChunk() : null;

        List<WorldSound> list = (chunk != null && !GameServer.server)
                ? chunk.soundList
                : WorldSoundManager.instance.soundList;

        // 静音 = hz_buff 的第 3 位（1=新生 2=开饭 4=饥饿 8=静音 16=受伤）
        // 只读这一位，其他 buff 与 Java 侧无关。
        boolean muted = false;
        if (zombie != null) {
            Object b = zombie.getModData().rawget("hz_buff");
            muted = (b instanceof Number) && ((((Number) b).intValue() & 8) != 0);
        }

        for (int i = 0; i < list.size(); i++) {
            WorldSound s = list.get(i);
            if (s == null) continue;
            if (!s.stressZombies) continue;
            if (s.radius == 0) continue;

            // 已派单的丧尸：忽略所有自定义声音；原版声音照常
            if (muted && s.source instanceof Number) {
                continue;
            }

            float distSq = IsoUtils.DistanceToSquared(
                    x, y, z * 3.0f,
                    s.x, s.y, s.z * 3.0f);

            float r = s.radius * WorldSoundManager.instance.getHearingMultiplier(zombie);

            if (distSq > r * r) continue;
            if (distSq < s.zombieIgnoreDist * s.zombieIgnoreDist && z == s.z) continue;
            if (flag4 && s.sourceIsZombie) continue;

            IsoGridSquare sqS = IsoWorld.instance.currentCell.getGridSquare(s.x, s.y, s.z);
            IsoGridSquare sqZ = IsoWorld.instance.currentCell.getGridSquare(x, y, z);

            float v = distSq / (r * r);

            if (sqS != null && sqZ != null && sqS.getRoom() != sqZ.getRoom()) {
                v *= 1.2f;
                if (sqZ.getRoom() != null && sqS.getRoom() == null) {
                    v *= 1.4f;
                }
            }

            v = 1.0f - v;
            if (v <= 0) continue;
            if (v > 1.0f) v = 1.0f;

            float val = s.volume * v;
            if (val > best) {
                best = val;
                bestSound = s;
            }
        }

        return result(bestSound, best);
    }
}
