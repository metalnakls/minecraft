// Copyright 2026 mcopt-shade contributors. Apache-2.0.
package minecraft.launcher.mixin;

import com.mojang.blaze3d.platform.InputConstants;
import net.minecraft.client.Minecraft;
import net.minecraft.client.ToggleKeyMapping;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/** A macOS shortcut must not toggle the sneak binding. Releases still reach vanilla. */
@Mixin(ToggleKeyMapping.class)
public abstract class CommandSneakMixin {
	@Inject(method = "setDown", at = @At("HEAD"), cancellable = true)
	private void launcher$commandSneak(boolean down, CallbackInfo ci) {
		if (down && (Object) this == Minecraft.getInstance().options.keyShift
			&& (InputConstants.isKeyDown(InputConstants.KEY_LGUI) || InputConstants.isKeyDown(InputConstants.KEY_RGUI))) ci.cancel();
	}
}
