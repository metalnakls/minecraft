// Copyright 2026 mcopt-shade contributors. Apache-2.0.
package minecraft.launcher.mixin;

import com.mojang.blaze3d.platform.InputConstants;
import net.minecraft.client.KeyMapping;
import net.minecraft.client.player.KeyboardInput;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Redirect;

/** Poll both command keys, including when shift was held before the shortcut began. */
@Mixin(KeyboardInput.class)
public abstract class CommandSneakInputMixin {
	@Redirect(method = "tick", at = @At(value = "INVOKE", target = "Lnet/minecraft/client/KeyMapping;isDown()Z", ordinal = 5))
	private boolean launcher$sneakWithoutCommand(KeyMapping key) {
		return key.isDown() && !InputConstants.isKeyDown(InputConstants.KEY_LGUI) && !InputConstants.isKeyDown(InputConstants.KEY_RGUI);
	}
}
