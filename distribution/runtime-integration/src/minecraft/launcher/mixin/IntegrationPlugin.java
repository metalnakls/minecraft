package minecraft.launcher.mixin;
import java.util.List;
import java.util.Set;
import org.objectweb.asm.tree.ClassNode;
import org.spongepowered.asm.mixin.extensibility.IMixinConfigPlugin;
import org.spongepowered.asm.mixin.extensibility.IMixinInfo;
/** Avoid duplicate redirects with old locally patched shader builds. */
public final class IntegrationPlugin implements IMixinConfigPlugin {
 public void onLoad(String p) {}
 public String getRefMapperConfig() { return null; }
 public boolean shouldApplyMixin(String target, String mixin) {
  String name = mixin.substring(mixin.lastIndexOf('.') + 1);
  return getClass().getClassLoader().getResource("mcopt/metal/mixin/" + name + ".class") == null;
 }
 public void acceptTargets(Set<String> mine, Set<String> others) {}
 public List<String> getMixins() { return null; }
 public void preApply(String t, ClassNode n, String m, IMixinInfo i) {}
 public void postApply(String t, ClassNode n, String m, IMixinInfo i) {}
}
